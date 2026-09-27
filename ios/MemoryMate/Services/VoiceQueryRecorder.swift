//
//  VoiceQueryRecorder.swift
//  MemoryMate
//

import AVFoundation
import Combine
import Foundation
import Speech

/// Records from the mic and streams results into `partialTranscript` for Voice-mode assistant.
@MainActor
final class VoiceQueryRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var partialTranscript = ""

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)

    private var lastTranscript = ""

    /// Speech + microphone authorization.
    func ensureAuthorized() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }
        let micOK: Bool = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                cont.resume(returning: allowed)
            }
        }
        return micOK
    }

    func startRecording() throws {
        cancelRecognition()
        partialTranscript = ""
        lastTranscript = ""

        guard let recognizer, recognizer.isAvailable else {
            throw VoiceRecorderError.recognizerUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let speechRequest = SFSpeechAudioBufferRecognitionRequest()
        speechRequest.shouldReportPartialResults = true
        request = speechRequest

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            speechRequest.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: speechRequest) { result, _ in
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor [weak self] in
                    self?.lastTranscript = text
                    self?.partialTranscript = text
                }
            }
        }

        isRecording = true
    }

    /// Ends capture and returns the best transcript (may be empty).
    func stopRecordingAndFinalizeTranscript() {
        guard isRecording else { return }
        isRecording = false

        request?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if partialTranscript.isEmpty, !lastTranscript.isEmpty {
            partialTranscript = lastTranscript
        }
    }

    func cancelRecognition() {
        if isRecording {
            isRecording = false
            request?.endAudio()
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum VoiceRecorderError: LocalizedError {
    case recognizerUnavailable
    case setupFailed

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is not available for this locale."
        case .setupFailed:
            return "Could not start the microphone for speech recognition."
        }
    }
}
