//
//  MelangeConfiguration.swift
//  MemoryMate
//

import Foundation
import ZeticMLange

/// Reads Melange keys from **merged** `Info.plist`: `Configuration/MemoryMateSecretsMerge.plist` supplies keys as
/// `$(MELANGE_…)` placeholders; values come from `Configuration/Secrets.xcconfig` (gitignored — copy from
/// `Secrets.example.xcconfig`). Plain `INFOPLIST_KEY_Melange*` entries were not appearing in the generated app plist
/// in this Xcode setup, so we use `INFOPLIST_FILE` merge instead.
///
/// **API split:** [`ZeticMLangeModel`](https://docs.zetic.ai/api-reference/ios/ZeticMLangeModel) takes `[Tensor]` (optional TexTeller-style CV stacks).
/// [`ZeticMLangeLLMModel`](https://docs.zetic.ai/api-reference/ios/ZeticMLangeLLMModel) accepts **`run(String)`** + `waitForNextToken()` only on iOS 1.6.x — no `UIImage` on that path; photo → text uses Vision OCR first, then Gemma on the transcript.
enum MelangeConfiguration {
    private static func string(for key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    static var personalKey: String? {
        string(for: "MelangePersonalKey")
    }

    static func requirePersonalKey() throws -> String {
        guard let key = personalKey else {
            throw MelangeConfigurationError.missingPersonalKey
        }
        return key
    }

    // MARK: - TexTeller (`ZeticMLangeModel`)

    static var texTellerEncoderName: String {
        string(for: "MelangeTexTellerEncoderName") ?? "OleehyO/TexTeller-encoder"
    }

    static var texTellerEncoderVersion: Int? {
        intPlist("MelangeTexTellerEncoderVersion") ?? 2
    }

    static var texTellerDecoderName: String {
        string(for: "MelangeTexTellerDecoderName") ?? "OleehyO/TexTeller-decoder"
    }

    static var texTellerDecoderVersion: Int? {
        intPlist("MelangeTexTellerDecoderVersion") ?? 1
    }

    /// First `decoder_input_ids` token for TrOCR (Hugging Face `decoder_start_token_id` on `OleehyO/TexTeller` is **2**).
    static var texTellerDecoderStartTokenId: Int32 {
        Int32(intPlist("MelangeTexTellerDecoderStartTokenId") ?? 2)
    }

    /// Padding for fixed-width CoreML `decoder_input_ids` (HF `pad_token_id` on `OleehyO/TexTeller` is **1**).
    static var texTellerDecoderPadTokenId: Int32 {
        Int32(intPlist("MelangeTexTellerDecoderPadTokenId") ?? 1)
    }

    /// Melange/CoreML TexTeller decoder often traces a **fixed** decoder sequence length (e.g. 80 int32 → 320 bytes). A `[1,1]` tensor triggers `got 4, expected 320` on `input` and leaves `input_1` unset. Override if your deployment spec differs.
    static var texTellerDecoderInputSequenceLength: Int {
        let v = intPlist("MelangeTexTellerDecoderInputSequenceLength") ?? 80
        return max(1, v)
    }

    /// Decoder logits last dimension (HF `OleehyO/TexTeller` `vocab_size` is **15000**).
    static var texTellerVocabSize: Int {
        let v = intPlist("MelangeTexTellerVocabSize") ?? 15_000
        return max(2, v)
    }

    /// Hugging Face Hub id used to download `tokenizer.json` for decoding logits (first run needs network). Should match the tokenizer trained with your TexTeller weights.
    static var texTellerTokenizerHubModelId: String {
        string(for: "MelangeTexTellerTokenizerHubModelId") ?? "OleehyO/TexTeller"
    }

    /// Decoder graph input order: `true` → `[decoder_input_ids, encoder_hidden_states]`; set `NO` in Info.plist if Melange expects the opposite.
    static var texTellerDecoderInputIdsBeforeEncoderStates: Bool {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MelangeTexTellerDecoderInputIdsFirst") else { return true }
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t == "0" || t == "false" || t == "no" { return false }
        }
        return true
    }

    static var texTellerInputWidth: Int {
        intPlist("MelangeTexTellerInputWidth") ?? 448
    }

    static var texTellerInputHeight: Int {
        intPlist("MelangeTexTellerInputHeight") ?? 448
    }

    /// ViT image mean (single grayscale channel), see TexTeller ONNX preprocessor defaults.
    static var texTellerImageMean: Double {
        doublePlist("MelangeTexTellerImageMean") ?? 0.954_546_7
    }

    static var texTellerImageStd: Double {
        doublePlist("MelangeTexTellerImageStd") ?? 0.153_944_45
    }

    // MARK: - Structuring LLM (`ZeticMLangeLLMModel`)

    /// When `MelangeStructuredLLMModelName` is set in the merged Info.plist (via `Secrets.xcconfig`), that value wins over the Swift fallback below.
    static var structuredLLMModelName: String {
        string(for: "MelangeStructuredLLMModelName") ?? "changgeun/gemma-4-E2B-it"
    }

    static var structuredLLMModelVersion: Int? {
        intPlist("MelangeStructuredLLMModelVersion") ?? 1
    }

    /// Max generated tokens for structured extraction. Override via Info key `MelangeStructuredLLMMaxGeneratedTokens`.
    static var structuredLLMMaxGeneratedTokens: Int {
        let value = intPlist("MelangeStructuredLLMMaxGeneratedTokens") ?? 8_192
        return max(256, value)
    }

    /// `RUN_SPEED` / `RUN_AUTO` / `RUN_ACCURACY` (Info key `MelangeStructuredLLMModelMode`). Default **RUN_AUTO** for Gemma-4 structured extraction.
    static var structuredLLMModelMode: LLMModelMode {
        guard let s = string(for: "MelangeStructuredLLMModelMode") else { return .RUN_AUTO }
        switch s.uppercased() {
        case "RUN_AUTO", "AUTO": return .RUN_AUTO
        case "RUN_ACCURACY", "ACCURACY": return .RUN_ACCURACY
        case "RUN_SPEED", "SPEED": return .RUN_SPEED
        default: return .RUN_AUTO
        }
    }

    private static func intPlist(_ key: String) -> Int? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) else { return nil }
        if raw is NSNull { return nil }
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func doublePlist(_ key: String) -> Double? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) else { return nil }
        if let d = raw as? Double { return d }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}

enum MelangeConfigurationError: LocalizedError {
    case missingPersonalKey

    var errorDescription: String? {
        switch self {
        case .missingPersonalKey:
            return "MelangePersonalKey is missing from Info.plist."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
