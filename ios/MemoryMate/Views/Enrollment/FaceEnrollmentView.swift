//
//  FaceEnrollmentView.swift
//  MemoryMate
//

import PhotosUI
import SwiftUI
import UIKit

private enum EnrollmentIdentityField: Hashable {
    case name
    case relation
}

struct FaceEnrollmentView: View {
    @StateObject private var vm = FaceEnrollmentVM()
    @State private var showCamera = false
    @State private var cameraCapture: UIImage?
    @FocusState private var identityField: EnrollmentIdentityField?

    var body: some View {
        NavigationStack {
            Form {
                Section("Photos (1–5)") {
                    if vm.maxGallerySlots > 0 {
                        PhotosPicker(
                            selection: $vm.selectedItems,
                            maxSelectionCount: min(5, vm.maxGallerySlots),
                            matching: .images
                        ) {
                            Label("Select photos", systemImage: "photo.on.rectangle")
                        }
                    } else {
                        Text("Library picks are full (5 photos). Remove a camera photo to add from the library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }

                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            guard vm.images.count < 5 else { return }
                            showCamera = true
                        } label: {
                            Label("Take photo", systemImage: "camera.fill")
                        }
                        .disabled(vm.images.count >= 5)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(vm.images.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(height: vm.images.isEmpty ? 0 : 88)

                    if !vm.images.isEmpty {
                        Text("\(vm.images.count) photo(s) — at least one clear face.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Identity") {
                    TextField("Name", text: $vm.name)
                        .textContentType(.name)
                        .focused($identityField, equals: .name)
                    TextField("Relation (e.g. Daughter)", text: $vm.relation)
                        .textContentType(.none)
                        .focused($identityField, equals: .relation)
                }
            }
            .navigationTitle("Enroll Person")
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissEnrollmentKeyboard() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    NavigationLink("Continue") {
                        FaceConfirmView(vm: vm)
                    }
                    .disabled(!vm.isReady)
                    .simultaneousGesture(TapGesture().onEnded { dismissEnrollmentKeyboard() })
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraImagePicker(image: $cameraCapture)
                    .ignoresSafeArea()
            }
            .onChange(of: vm.selectedItems) { _, _ in
                Task { await vm.syncPickerSelectionWithCap() }
            }
            .onChange(of: vm.cameraImages.count) { _, _ in
                Task { await vm.syncPickerSelectionWithCap() }
            }
            .onChange(of: cameraCapture) { _, new in
                if let new {
                    vm.appendCameraImage(new)
                    cameraCapture = nil
                }
            }
            .onChange(of: showCamera) { _, presented in
                if presented { dismissEnrollmentKeyboard() }
            }
            .onDisappear {
                dismissEnrollmentKeyboard()
            }
            .task {
                await vm.syncPickerSelectionWithCap()
            }
        }
    }

    private func dismissEnrollmentKeyboard() {
        identityField = nil
        Keyboard.dismiss()
    }
}
