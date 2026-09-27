//
//  MedicationVM.swift
//  MemoryMate
//

import Combine
import Foundation

enum MedicationImportError: LocalizedError {
    case emptyList
    case emptyDrugAtRows([Int])

    var errorDescription: String? {
        switch self {
        case .emptyList:
            return "Add at least one medication before saving."
        case .emptyDrugAtRows(let rows):
            let list = rows.map { String($0 + 1) }.joined(separator: ", ")
            return "Drug name is required on row(s): \(list)."
        }
    }
}

enum MedicationImportParseError: LocalizedError {
    case invalidUTF8
    case notJSONArrayOrObject
    case emptyMedicationArray
    /// e.g. `["drug","10","345"]` instead of `[{"drug":"…","dose":"…",…}]`.
    case expectedMedicationObjectsGotStringList
    /// Gemma returned prose, markdown, or broken JSON that could not be repaired.
    case jsonNotRecoverable(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The model output was not valid UTF-8 text."
        case .notJSONArrayOrObject:
            return "Expected a JSON array of medication objects, or an object wrapping such an array."
        case .emptyMedicationArray:
            return "Model returned an empty medication array ([])."
        case .expectedMedicationObjectsGotStringList:
            return "The model returned a JSON array of plain strings (fragments) instead of objects. Each item must be one object: {\"drug\":\"…\",\"dose\":\"…\",\"times\":[\"…\"],\"condition\":\"…\"}. Tap Run again, or edit rows manually in Review."
        case .jsonNotRecoverable(let hint):
            return "Gemma output was not valid JSON. \(hint)"
        }
    }
}

@MainActor
final class MedicationVM: ObservableObject {
    /// Parsed / edited medications before batch upload (no cloud — only Pi HTTP).
    @Published var importItems: [MedicationRequest] = []

    func applyImportedMedications(from ocrOrSpeechText: String) {
        let parsed = MedicationParser().parseMany(from: ocrOrSpeechText)
        importItems = parsed.map {
            MedicationRequest(
                drug: $0.drug,
                dose: $0.dose,
                times: $0.times,
                condition: $0.condition
            )
        }
        if importItems.isEmpty {
            let fallbackCondition = MedicationParser.extractConditionForDisplay(from: ocrOrSpeechText)
            importItems = [
                MedicationRequest(drug: "", dose: "", times: [], condition: fallbackCondition),
            ]
        }
    }

    /// Parses Gemma (or other) JSON output after stripping optional ``` fences, then fills `importItems` for `MedConfirmListView`.
    func applyImportedMedications(fromStructuredGemmaOutput raw: String) throws {
        let stripped = Self.stripMarkdownCodeFences(raw)
        var normalized = Self.normalizeLLMJSONShell(stripped)
        normalized = Self.closeUnbalancedJSONArrayIfNeeded(normalized)
        guard let data = normalized.data(using: .utf8) else { throw MedicationImportParseError.invalidUTF8 }

        let any: Any
        do {
            any = try Self.jsonObjectLenient(fromUTF8: data)
        } catch {
            throw MedicationImportParseError.jsonNotRecoverable(
                "Try again or shorten the OCR text. Parse error: \(error.localizedDescription)."
            )
        }

        if let top = any as? [Any], !top.isEmpty, top.allSatisfy({ $0 is String }) {
            throw MedicationImportParseError.expectedMedicationObjectsGotStringList
        }

        let rows: [[String: Any]]
        if let arr = any as? [[String: Any]] {
            rows = arr
        } else if let dict = any as? [String: Any] {
            // Accept common wrappers OR a single medication object at top level.
            let candidates = ["medications", "medication", "items", "rows", "data", "results", "list"]
            var found: [[String: Any]]?
            for key in candidates {
                if let arr = dict[key] as? [[String: Any]] {
                    found = arr
                    break
                }
                if let nested = dict[key] as? [String: Any] {
                    found = [nested]
                    break
                }
            }
            if let arr = found {
                rows = arr
            } else if Self.looksLikeMedicationObject(dict) {
                rows = [dict]
            } else {
                throw MedicationImportParseError.notJSONArrayOrObject
            }
        } else {
            throw MedicationImportParseError.notJSONArrayOrObject
        }

        importItems = rows.map { dict in
            let drug = Self.normalizedString(dict["drug"])
            let dose = Self.normalizedString(dict["dose"])
            var condition = Self.normalizedString(dict["condition"])
            var times = Self.normalizedTimes(dict["times"])
            Self.stripConditionThatDuplicatesTimes(condition: &condition, times: times)
            return MedicationRequest(drug: drug, dose: dose, times: times, condition: condition)
        }

        importItems = Self.dedupeConsecutiveIdentical(importItems)
        if importItems.isEmpty {
            throw MedicationImportParseError.emptyMedicationArray
        }
    }

    /// Coerces LLM mistakes (`times` as a single string) into `[String]`.
    private static func normalizedTimes(_ value: Any?) -> [String] {
        if let arr = value as? [String] {
            return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let arr = value as? [Any] {
            return arr.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return [] }
            return [t]
        }
        if let n = value as? NSNumber {
            return [n.stringValue]
        }
        return []
    }

    private static func normalizedString(_ value: Any?) -> String {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    /// Models often echo schedule into `condition`; drop when it matches `times`.
    private static func stripConditionThatDuplicatesTimes(condition: inout String, times: [String]) {
        let c = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        let lower = c.lowercased()
        for slot in times {
            let t = slot.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if lower == t.lowercased() {
                condition = ""
                return
            }
        }
        let joined = times.joined(separator: " ").lowercased()
        if !joined.isEmpty, lower == joined {
            condition = ""
        }
    }

    private static func dedupeConsecutiveIdentical(_ items: [MedicationRequest]) -> [MedicationRequest] {
        guard !items.isEmpty else { return items }
        var out: [MedicationRequest] = []
        out.reserveCapacity(items.count)
        for item in items {
            if let last = out.last,
               last.drug == item.drug,
               last.dose == item.dose,
               last.times == item.times,
               last.condition == item.condition {
                continue
            }
            out.append(item)
        }
        return out
    }

    private static func looksLikeMedicationObject(_ dict: [String: Any]) -> Bool {
        let keys = Set(dict.keys.map { $0.lowercased() })
        let medicationKeys = ["drug", "dose", "times", "condition"]
        return medicationKeys.contains { keys.contains($0) }
    }

    /// Pulls the first ``` … ``` block if present (models often prefix with "Here is the JSON:").
    private static func stripMarkdownCodeFences(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = t.range(of: "```") else { return t }
        var inner = String(t[open.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasPrefix("json") {
            inner = String(inner.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if inner.hasPrefix("JSON") {
            inner = String(inner.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let close = inner.range(of: "```") {
            return String(inner[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return inner
    }

    private static func normalizeLLMJSONShell(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "\u{201C}", with: "\"")
        t = t.replacingOccurrences(of: "\u{201D}", with: "\"")
        t = t.replacingOccurrences(of: "\u{2018}", with: "'")
        t = t.replacingOccurrences(of: "\u{2019}", with: "'")
        return removeTrailingCommasBeforeClosingBrackets(in: t)
    }

    /// When the model truncates before `]`, `JSONSerialization` may fall back to the first `{...}` only → one Review row. Close open `{` and add `]`.
    private static func closeUnbalancedJSONArrayIfNeeded(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.first == "[", t.last != "]" else { return s }

        let inner = t.index(after: t.startIndex) ..< t.endIndex
        var netBraces = 0
        var inString = false
        var escape = false
        var i = inner.lowerBound
        while i < inner.upperBound {
            let c = t[i]
            if escape {
                escape = false
                i = t.index(after: i)
                continue
            }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                i = t.index(after: i)
                continue
            }
            if c == "\"" {
                inString = true
                i = t.index(after: i)
                continue
            }
            if c == "{" { netBraces += 1 }
            if c == "}" { netBraces -= 1 }
            i = t.index(after: i)
        }

        var out = t
        while out.last?.isWhitespace == true { out.removeLast() }
        while out.last == "," {
            out.removeLast()
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if netBraces > 0 {
            out.append(String(repeating: "}", count: netBraces))
        }
        out.append("]")
        return out
    }

    private static func removeTrailingCommasBeforeClosingBrackets(in json: String) -> String {
        var s = json
        let pairs = [(#",\s*\]"#, "]"), (#",\s*\}"#, "}")]
        for (pattern, template) in pairs {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
        }
        return s
    }

    /// `JSONSerialization` with repairs; extracts first top-level `[...]` or `{...}` when the model adds prose around JSON.
    private static func jsonObjectLenient(fromUTF8 data: Data) throws -> Any {
        guard var text = String(data: data, encoding: .utf8) else {
            throw MedicationImportParseError.invalidUTF8
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let o = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.mutableContainers]) {
            return o
        }
        var candidates: [String] = [text]
        let repairedArray = closeUnbalancedJSONArrayIfNeeded(text)
        if repairedArray != text {
            candidates.append(repairedArray)
        }
        if let sub = firstBalancedJSONFragment(open: "[", close: "]", in: text) {
            candidates.append(String(sub))
        }
        if let sub = firstBalancedJSONFragment(open: "{", close: "}", in: text) {
            candidates.append(String(sub))
        }
        for candidate in candidates {
            let c = normalizeLLMJSONShell(candidate)
            guard let d = c.data(using: .utf8) else { continue }
            if let o = try? JSONSerialization.jsonObject(with: d, options: [.mutableContainers]) {
                return o
            }
        }
        return try JSONSerialization.jsonObject(with: data, options: [.mutableContainers])
    }

    /// Bracket/brace depth scan that ignores `[` `]` `{` `}` inside quoted strings.
    private static func firstBalancedJSONFragment(open: Character, close: Character, in text: String) -> Substring? {
        guard let startIdx = text.firstIndex(of: open) else { return nil }
        var depth = 0
        var i = startIdx
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
            if c == open { depth += 1 }
            else if c == close {
                depth -= 1
                if depth == 0 { return text[startIdx...i] }
            }
            i = text.index(after: i)
        }
        return nil
    }

    func appendEmptyImportItem() {
        let sharedCondition = importItems.first?.condition ?? ""
        importItems.append(MedicationRequest(drug: "", dose: "", times: [], condition: sharedCondition))
    }

    func deleteImportItems(_ offsets: IndexSet) {
        var copy = importItems
        for i in offsets.sorted(by: >) {
            guard copy.indices.contains(i) else { continue }
            copy.remove(at: i)
        }
        importItems = copy
    }

    func replaceImportItem(at index: Int, with item: MedicationRequest) {
        guard importItems.indices.contains(index) else { return }
        importItems[index] = item
    }

    func saveAllImported() async throws {
        guard !importItems.isEmpty else { throw MedicationImportError.emptyList }

        let emptyRows = importItems.enumerated()
            .filter { $0.element.drug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.offset)
        guard emptyRows.isEmpty else {
            throw MedicationImportError.emptyDrugAtRows(emptyRows)
        }

        struct Created: Decodable {
            let id: String
        }

        for var item in importItems {
            item.drug = item.drug.trimmingCharacters(in: .whitespacesAndNewlines)
            item.dose = item.dose.trimmingCharacters(in: .whitespacesAndNewlines)
            item.condition = item.condition.trimmingCharacters(in: .whitespacesAndNewlines)
            item.times = item.times.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let _: Created = try await APIService.shared.post("/add-medication", body: item)
        }
    }

    func resetImportSession() {
        importItems = []
    }

}
