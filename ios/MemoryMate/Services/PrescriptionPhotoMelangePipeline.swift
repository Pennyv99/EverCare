//
//  PrescriptionPhotoMelangePipeline.swift
//  MemoryMate
//

import UIKit

/// Prescription photo → **Apple Vision** OCR string → **one** Melange `ZeticMLangeLLMModel` call (`run` + token loop) → medication JSON.
///
/// The Melange iOS LLM API matches the deployment snippet (`run("prompt")`, `waitForNextToken()` until `generatedTokens == 0`).
/// There is no image argument on `ZeticMLangeLLMModel`; pixels are turned into text with `Vision` first, then Gemma does cleanup + structured extraction in a single prompt.
struct PrescriptionPhotoMelangePipeline: Sendable {
    private let ocr = OCRService()
    private let gemma = GemmaMedicationStructuringService()

    /// Raw lines from on-device Vision OCR (no Melange).
    func visionOCRText(from image: UIImage) async throws -> String {
        try await ocr.recognizeText(from: image)
    }

    /// Vision OCR text → Gemma JSON (same `MelangeLLMGenerationService` / token loop as dashboard).
    func medicationsJSON(fromOCRText ocrText: String) async throws -> String {
        try await gemma.structureMedicationsJSON(fromTranscript: ocrText)
    }

    /// Full path for the photo button: OCR then Gemma.
    func run(image: UIImage) async throws -> (visionOCRText: String, gemmaOutput: String) {
        let visionOCRText = try await visionOCRText(from: image)
        let gemmaOutput = try await medicationsJSON(fromOCRText: visionOCRText)
        return (visionOCRText, gemmaOutput)
    }
}
