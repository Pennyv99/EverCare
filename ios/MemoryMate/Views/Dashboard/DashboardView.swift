//
//  DashboardView.swift
//  MemoryMate
//

import AVFoundation
import Combine
import SwiftUI

private enum AssistantInputMode: String, CaseIterable {
    case text
    case voice

    var title: String {
        switch self {
        case .text: return "Text"
        case .voice: return "Voice"
        }
    }
}

private let assistantWaitNudges: [String] = [
    "Hang tight — your Pi is working on it.",
    "Roll your shoulders once.",
    "Take a slow breath in… and out.",
    "Notice one thing you can hear nearby.",
    "Almost there — thanks for your patience.",
]

private enum AssistantClientError: LocalizedError {
    case emptyVoiceTranscript
    case speechPermissionDenied

    var errorDescription: String? {
        switch self {
        case .emptyVoiceTranscript:
            return "No speech was recognized. Try again or switch to Text mode."
        case .speechPermissionDenied:
            return "Microphone and speech recognition must be allowed in Settings to use Voice mode."
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var appError: AppErrorState
    @StateObject private var voiceRecorder = VoiceQueryRecorder()

    @State private var people: [Person] = []
    @State private var medications: [Medication] = []
    @State private var isLoading = false

    @State private var assistantMode: AssistantInputMode = .text
    @State private var assistantQuery = ""
    @State private var assistantReply = ""
    @State private var lastVoiceTranscript = ""
    @State private var isAssistantBusy = false
    @State private var assistantWaitNudgeIndex = 0
    @State private var replyAudioPlayer: AVAudioPlayer?
    @State private var loadFailure: String?

    private let assistantWaitNudgeTimer = Timer.publish(every: 1.8, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    assistantHeroCard
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 14, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let loadFailure {
                    Section {
                        Text(loadFailure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Summary") {
                    LabeledContent("People", value: "\(people.count)")
                    LabeledContent("Medications", value: "\(medications.count)")
                }

                Section("People") {
                    NavigationLink("View all") {
                        PeopleListView(people: people, reload: { await load() })
                            .navigationTitle("People")
                    }
                }

                Section("Medications") {
                    NavigationLink("View all") {
                        MedicationListView(medications: medications, reload: { await load() })
                            .navigationTitle("Medications")
                    }
                }
            }
            .navigationTitle("Home")
            .refreshable { await load(showAlert: false) }
            .overlay {
                if isLoading && people.isEmpty && medications.isEmpty {
                    ProgressView()
                }
            }
            .onAppear { Task { await load(showAlert: false) } }
            .onChange(of: assistantMode) { _, newMode in
                if newMode == .text {
                    voiceRecorder.cancelRecognition()
                }
            }
            .onReceive(assistantWaitNudgeTimer) { _ in
                guard isAssistantBusy else { return }
                assistantWaitNudgeIndex = (assistantWaitNudgeIndex + 1) % assistantWaitNudges.count
            }
        }
    }

    private var assistantHeroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask EverCare")
                        .font(.title2.weight(.bold))
                    Text("Your care companion — questions, reminders, medications")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Picker("Mode", selection: $assistantMode) {
                ForEach(AssistantInputMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isAssistantBusy)

            if isAssistantBusy {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(assistantWaitNudges[assistantWaitNudgeIndex % assistantWaitNudges.count])
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Assistant is working")
            }

            Group {
                switch assistantMode {
                case .text:
                    TextField("What medications do I have today?", text: $assistantQuery, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isAssistantBusy)

                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            Task { await runAssistantTextMode() }
                        } label: {
                            Label("Send", systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(isAssistantBusy || trimmedAssistantQuery.isEmpty)
                    }
                case .voice:
                    Text("Speak your question, then tap Stop & send.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if voiceRecorder.isRecording || !voiceRecorder.partialTranscript.isEmpty {
                        Text(voiceRecorder.partialTranscript.isEmpty ? "Listening…" : voiceRecorder.partialTranscript)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                    }

                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            Task { await toggleVoiceAssistant() }
                        } label: {
                            Label(
                                voiceRecorder.isRecording ? "Stop & send" : "Tap to speak",
                                systemImage: voiceRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(voiceRecorder.isRecording ? .orange : .blue)
                        .disabled(isAssistantBusy)
                        Spacer(minLength: 0)
                    }

                    if !lastVoiceTranscript.isEmpty {
                        Text("Last: \(lastVoiceTranscript)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !assistantReply.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reply")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(assistantReply)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.blue.opacity(0.45),
                            Color.purple.opacity(0.35),
                            Color.blue.opacity(0.2),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        }
    }

    private func load(showAlert: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let faces: [Person] = APIService.shared.get("/enrolled-faces")
            async let meds: [Medication] = APIService.shared.get("/medications")
            (people, medications) = try await (faces, meds)
            loadFailure = nil
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            loadFailure = text
            print("[MemoryMate][Home] load failed: \(text)")
            if showAlert {
                appError.present(error)
            }
        }
    }

    private var trimmedAssistantQuery: String {
        assistantQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runAssistantTextMode() async {
        let q = trimmedAssistantQuery
        guard !q.isEmpty else { return }
        isAssistantBusy = true
        assistantWaitNudgeIndex = 0
        defer { isAssistantBusy = false }
        lastVoiceTranscript = ""
        do {
            let body = AgentAPIRequest(query: q, timeout: 60)
            let result: AgentAPIResponse = try await APIService.shared.post("/agent", body: body)
            assistantReply = Self.formatAgentReply(result)
        } catch {
            assistantReply = ""
            appError.present(error)
        }
    }

    /// Voice: on-device speech-to-text, then **only** `POST /agent-voice` (MP3). No `/agent` call.
    private func runVoiceAssistantPipeline(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            appError.present(AssistantClientError.emptyVoiceTranscript)
            return
        }
        lastVoiceTranscript = q
        isAssistantBusy = true
        assistantWaitNudgeIndex = 0
        defer { isAssistantBusy = false }
        assistantReply = ""
        let body = AgentAPIRequest(query: q, timeout: 60)
        do {
            let mp3 = try await APIService.shared.postReturningData("/agent-voice", body: body)
            try playAgentVoiceMP3(mp3)
        } catch {
            assistantReply = "Couldn’t play the spoken reply. What we heard:\n\n\(q)"
            appError.present(error)
        }
    }

    private func toggleVoiceAssistant() async {
        if voiceRecorder.isRecording {
            voiceRecorder.stopRecordingAndFinalizeTranscript()
            let q = voiceRecorder.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            await runVoiceAssistantPipeline(query: q)
            return
        }
        let ok = await voiceRecorder.ensureAuthorized()
        guard ok else {
            appError.present(AssistantClientError.speechPermissionDenied)
            return
        }
        assistantReply = ""
        do {
            try voiceRecorder.startRecording()
        } catch {
            appError.present(error)
        }
    }

    private static func formatAgentReply(_ r: AgentAPIResponse) -> String {
        switch r.status {
        case "success":
            return r.response
        case "timeout":
            return r.error ?? "The assistant timed out. Try a shorter question."
        case "error":
            return r.error ?? r.response
        default:
            if let err = r.error, !err.isEmpty { return err }
            return r.response
        }
    }

    private func playAgentVoiceMP3(_ data: Data) throws {
        replyAudioPlayer?.stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        let player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
        replyAudioPlayer = player
        player.play()
    }
}
