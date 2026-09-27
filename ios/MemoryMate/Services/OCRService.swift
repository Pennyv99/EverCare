//
//  OCRService.swift
//  MemoryMate
//

import Foundation
import UIKit
import Vision

enum OCRError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Could not read that image for text recognition."
        }
    }
}

struct OCRService {
    func recognizeText(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImageForVision() else { throw OCRError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            final class ResumeBox: @unchecked Sendable {
                private let lock = NSLock()
                private var didResume = false
                func resume(_ action: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    action()
                }
            }
            let box = ResumeBox()

            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    box.resume { continuation.resume(throwing: error) }
                    return
                }
                let text = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n") ?? ""
                print("[MemoryMate][VisionOCR] characters=\(text.count)")
                print(text)
                box.resume { continuation.resume(returning: text) }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // English first (per spec); include Chinese for common local prescriptions.
            request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]

            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    box.resume { continuation.resume(throwing: error) }
                }
            }
        }
    }
}
