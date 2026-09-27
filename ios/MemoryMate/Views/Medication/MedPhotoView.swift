//
//  MedPhotoView.swift
//  MemoryMate
//

import Combine
import PhotosUI
import SwiftUI
import UIKit

private let medPipelineWaitNudges: [String] = [
    "Stretch your fingers for a moment.",
    "Notice your breathing — in and out.",
    "This step uses on-device Vision, then your Pi for Gemma.",
    "You can glance away from the screen for a bit.",
    "Thanks for waiting — almost done.",
]

private enum PhotoPickError: LocalizedError {
    case couldNotLoadData
    case couldNotDecodeImage

    var errorDescription: String? {
        switch self {
        case .couldNotLoadData:
            return "Could not load the photo file. If it is in iCloud, open Photos and wait until it finishes downloading, then pick it again."
        case .couldNotDecodeImage:
            return "Could not open the selected image."
        }
    }
}

struct MedPhotoView: View {
    @ObservedObject var vm: MedicationVM
    @EnvironmentObject private var appError: AppErrorState

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var isOCRRunning = false
    @State private var isLLMRunning = false
    @State private var ocrSummary: String?
    @State private var gemmaSummary: String?
    @State private var parseFooter: String?
    @State private var showCamera = false
    @State private var isVisionExpanded = false
    @State private var isGemmaExpanded = true
    @State private var medWaitNudgeIndex = 0

    private let melangePipeline = PrescriptionPhotoMelangePipeline()
    private let medWaitNudgeTimer = Timer.publish(every: 1.8, on: .main, in: .common).autoconnect()

    private var isBusy: Bool { isOCRRunning || isLLMRunning }

    var body: some View {
        Form {
            Section("Prescription photo") {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(image == nil ? "Select photo" : "Change photo", systemImage: "photo")
                }
                .onChange(of: pickerItem) { _, newValue in
                    Task { await loadImage(from: newValue) }
                }

                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        resetAnalysisOutput()
                        showCamera = true
                    } label: {
                        Label("Take photo", systemImage: "camera.fill")
                    }
                }

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if pickerItem != nil {
                    ProgressView("Loading photo…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
            }

            if let ocrSummary {
                Section {
                    DisclosureGroup("Vision OCR", isExpanded: $isVisionExpanded) {
                        ScrollView {
                            Text(ocrSummary)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    }
                }
            }

            if let gemmaSummary {
                Section {
                    DisclosureGroup("Gemma output", isExpanded: $isGemmaExpanded) {
                        ScrollView {
                            Text(gemmaSummary)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 260)
                    }
                }
            }

            if let parseFooter {
                Section {
                    Text(parseFooter)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await runOCRThenLLM() }
                } label: {
                    if isOCRRunning {
                        Label("Reading prescription…", systemImage: "text.viewfinder")
                    } else if isLLMRunning {
                        Label("Structuring medications…", systemImage: "wand.and.stars")
                    } else {
                        Label("Run Vision OCR", systemImage: "wand.and.stars")
                    }
                }
                .disabled(image == nil || isBusy)
            } footer: {
                if image == nil, pickerItem != nil {
                    Text("Still loading the image, or it failed to load. Check the error alert if one appeared.")
                } else if image == nil {
                    Text("Choose or take a photo first. The button stays disabled until the image is ready.")
                }
            }
        }
        .safeAreaPadding(.bottom, 40)
        .navigationTitle("Photo entry")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                NavigationLink("Review") {
                    MedConfirmListView(vm: vm)
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraImagePicker(image: $image)
                .ignoresSafeArea()
        }
        .onChange(of: image) { _, newImage in
            if newImage != nil {
                pickerItem = nil
                resetAnalysisOutput()
            }
        }
        .overlay {
            if isBusy {
                ZStack {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.15)
                        Text(isOCRRunning ? "Vision OCR" : "Gemma")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(isOCRRunning ? "Reading text from your photo…" : "Turning lines into medication rows…")
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                        Text(medPipelineWaitNudges[medWaitNudgeIndex % medPipelineWaitNudges.count])
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(26)
                    .frame(maxWidth: 300)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.ultraThickMaterial)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
                }
                .allowsHitTesting(true)
            }
        }
        .onReceive(medWaitNudgeTimer) { _ in
            guard isBusy else { return }
            medWaitNudgeIndex = (medWaitNudgeIndex + 1) % medPipelineWaitNudges.count
        }
    }

    private func loadImage(from item: PhotosPickerItem?) async {
        // Do not clear `image` when `item` is nil — the user may have set it with the camera.
        guard let item else { return }
        resetAnalysisOutput()
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PhotoPickError.couldNotLoadData
            }
            guard let uiImage = UIImage(data: data) else {
                throw PhotoPickError.couldNotDecodeImage
            }
            image = uiImage
        } catch {
            image = nil
            appError.present(error)
        }
    }

    private func runOCRThenLLM() async {
        guard let image else { return }
        parseFooter = nil
        gemmaSummary = nil

        isOCRRunning = true
        medWaitNudgeIndex = 0
        let ocrText: String
        do {
            ocrText = try await melangePipeline.visionOCRText(from: image)
        } catch {
            isOCRRunning = false
            ocrSummary = nil
            appError.present(error)
            return
        }
        isOCRRunning = false

        let ocrTrim = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ocrBlock = "Vision OCR (\(ocrTrim.count) chars):\n\(Self.debugPreview(ocrTrim, limit: 12_000))"
        ocrSummary = ocrBlock
        print("[MemoryMate][VisionOCR][complete] chars=\(ocrTrim.count)")
        print(ocrBlock)

        isLLMRunning = true
        medWaitNudgeIndex = 0
        let gemmaRaw: String
        do {
            gemmaRaw = try await melangePipeline.medicationsJSON(fromOCRText: ocrText)
        } catch {
            isLLMRunning = false
            gemmaSummary = nil
            parseFooter = "Gemma generation failed."
            appError.present(error)
            return
        }
        isLLMRunning = false

        let gemmaPreviewLimit = 2_200
        let gemmaBlock = "Gemma output (\(gemmaRaw.count) chars):\n\(Self.debugPreview(gemmaRaw, limit: gemmaPreviewLimit))"
        gemmaSummary = gemmaBlock
        print("[MemoryMate][Gemma][complete] chars=\(gemmaRaw.count)")

        do {
            try vm.applyImportedMedications(fromStructuredGemmaOutput: gemmaRaw)
            parseFooter = "Parsed into Review list — open Review to edit all rows."
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            vm.resetImportSession()
            parseFooter = "Gemma parse failed: \(msg). No OCR fallback — see Xcode console for [MemoryMate][Gemma][raw] full output."
            appError.present(error)
        }
    }

    private func resetAnalysisOutput() {
        ocrSummary = nil
        gemmaSummary = nil
        parseFooter = nil
        isVisionExpanded = false
        isGemmaExpanded = true
    }

    /// Long transcript preview for the form (scrollable + text selection).
    private static func debugPreview(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "\n… truncated, \(s.count) chars total"
    }
}
