//
//  GemmaMedicationStructuringService.swift
//  MemoryMate
//

import Foundation

/// Uses `ZeticMLangeLLMModel` (defaults: `changgeun/gemma-4-E2B-it` v1, `RUN_AUTO` — see `MelangeConfiguration`) for medication JSON from OCR text.
struct GemmaMedicationStructuringService: Sendable {
    /// Must match the suffix of `buildPrompt` after `<start_of_turn>model` so `assembleJSONArrayOutput` can prepend the same opening.
    private static let jsonArrayObjectPrefill = "[\n  {"

    func structureMedicationsJSON(fromTranscript transcript: String) async throws -> String {
        let prompt = Self.buildPrompt(transcript: transcript)
        // Gemma-4 may spend many tokens in `<|channel>thought` before JSON; 300 is too small and yields only prose + `[]` after sanitize.
        let raw = try await MelangeLLMGenerationService.shared.generate(
            prompt: prompt,
            modelName: MelangeConfiguration.structuredLLMModelName,
            modelVersion: MelangeConfiguration.structuredLLMModelVersion,
            maxGeneratedTokens: MelangeConfiguration.structuredLLMMaxGeneratedTokens,
            onDownloadProgress: nil
        )
        let assembled = Self.assembleJSONArrayOutput(from: raw)
        print("[MemoryMate][Gemma][assembled-for-parser] chars=\(assembled.count)\n\(assembled)")
        return assembled
    }

    /// Strips Gemma 4 `<|channel|>` thought blocks, slices from the first `[`, then turns output into a JSON array of objects (full-array replies or `[` + `{` prefill).
    private static func assembleJSONArrayOutput(from raw: String) -> String {
        var text = raw

        // Gemma 4 may emit thought-channel tokens (`<|channel|>thought` or `<|channel>thought`).
        // Keep only the content after the last channel tag when present.
        let normalizedChannel = text.replacingOccurrences(of: "<|channel>", with: "<|channel|>")
        if let channelTail = normalizedChannel.range(of: "<|channel|>", options: .backwards) {
            let afterChannel = String(normalizedChannel[channelTail.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !afterChannel.isEmpty {
                text = afterChannel
            } else {
                text = normalizedChannel
            }
        } else {
            text = normalizedChannel
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let medicationArray = extractLikelyMedicationJSONArray(in: text) {
            return medicationArray
        }

        if let arrayStart = text.firstIndex(of: "[") {
            text = String(text[arrayStart...])
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let medicationArray = extractLikelyMedicationJSONArray(in: t) {
            return medicationArray
        }

        if t.hasPrefix("["), let data = t.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? [Any] {
            if obj.isEmpty {
                return t
            }
            if let first = obj.first {
                if first is [String: Any] || first is NSDictionary {
                    return t
                }
                // Wrong shape (e.g. array of strings) — return unchanged for a clear parse error.
                if first is String {
                    return t
                }
            }
        }

        var continuation = t
        while continuation.hasPrefix("[") {
            continuation.removeFirst()
            continuation = continuation.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if continuation.hasPrefix("{") {
            continuation.removeFirst()
            continuation = continuation.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rebuilt = Self.jsonArrayObjectPrefill + continuation
        if let medicationArray = extractLikelyMedicationJSONArray(in: rebuilt) {
            return medicationArray
        }
        // Hard fail-safe: never surface CoT/prose in UI. If no medication array is extractable, return empty JSON array.
        return "[]"
    }

    /// Returns the first balanced top-level JSON array (`[...]`) while ignoring brackets inside quoted strings.
    private static func extractFirstJSONArray(in text: String) -> String? {
        guard let start = text.firstIndex(of: "[") else { return nil }
        var i = start
        var depth = 0
        var inString = false
        var escape = false
        while i < text.endIndex {
            let c = text[i]
            if escape {
                escape = false
                i = text.index(after: i)
                continue
            }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                i = text.index(after: i)
                continue
            }
            if c == "\"" {
                inString = true
                i = text.index(after: i)
                continue
            }
            if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...i]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Best-effort extractor for medication JSON arrays, skipping CoT/prose before the array.
    private static func extractLikelyMedicationJSONArray(in text: String) -> String? {
        if let idx = firstRegexMatchIndex(#"\[\s*\{\s*"drug"\s*:"#, in: text) {
            let tail = String(text[idx...])
            if let arr = extractFirstJSONArray(in: tail) {
                return arr
            }
        }
        if let idx = firstRegexMatchIndex(#"\{\s*"drug"\s*:"#, in: text) {
            let tail = String(text[idx...])
            if let obj = extractFirstBalancedJSONObject(in: tail) {
                return "[\(obj)]"
            }
        }
        return nil
    }

    private static func firstRegexMatchIndex(_ pattern: String, in text: String) -> String.Index? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range, in: text) else { return nil }
        return range.lowerBound
    }

    private static func extractFirstBalancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var i = start
        var depth = 0
        var inString = false
        var escape = false
        while i < text.endIndex {
            let c = text[i]
            if escape {
                escape = false
                i = text.index(after: i)
                continue
            }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                i = text.index(after: i)
                continue
            }
            if c == "\"" {
                inString = true
                i = text.index(after: i)
                continue
            }
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...i]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func buildPrompt(transcript: String) -> String {
        let user = """
        <start_of_turn>user
        You are a pharmacy data extractor. Read the prescription and output ONLY one JSON value: a top-level array whose elements are JSON objects.
        You must respond using the <|channel|>final channel.
        Do not output anything in <|channel|>thought.
        Do not include reasoning.
        Output ONLY the final JSON.

        Strict output constraints:
        - No explanation
        - No thinking process
        - No extra text
        - No markdown
        - No prefix or suffix
        - First character must be `[`
        - Last character must be `]`

        Each object MUST have exactly these keys (use straight ASCII double quotes on keys and string values):
        - "drug": medication name exactly as printed in the prescription (string)
        - "dose": strength only, e.g. "195 mg" or "10 mg" (string)
        - "times": a JSON array of one or more frequency strings, e.g. ["every 12 hours"] or ["OD"] — never a single bare string for the whole field
        - "condition": diagnosis, food instruction, or duration line if useful; else "" (string)

        FORBIDDEN: a JSON array of bare strings or numbers, e.g. ["drug","10","345","1/tablet"]. That is not valid output.
        FORBIDDEN: any field named "thought", "analysis", or "reasoning".

        REQUIRED shape (example only — replace with real values from the prescription):
        [{"drug":"EXAMPLE NAME","dose":"10 mg","times":["every 8 hours"],"condition":""}]
        Single-object example:
        {"drug":"Amlodipine","dose":"5 mg"}

        The assistant message you are completing already ends with an opening array and the start of the first object. Your next tokens must continue that first object (e.g. with "drug": "…", then the other keys), then add more comma-separated objects if needed, then close the array with ].

        Rules:
        - Copy drug names ONLY from the prescription text; do not invent medicines.
        - Do not output ``` or any markdown.

        Prescription:
        \(transcript)
        <end_of_turn>
        <start_of_turn>model

        """
        return user + Self.jsonArrayObjectPrefill
    }
}
