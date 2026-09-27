//
//  MedicationParser.swift
//  MemoryMate
//

import Foundation

struct ParsedMedication: Equatable {
    var drug: String = ""
    var dose: String = ""
    var times: [String] = []
    var condition: String = ""
}

struct MedicationParser {

    /// Exposes diagnosis line for manual entry when table rows are not detected.
    static func extractConditionForDisplay(from text: String) -> String {
        extractCondition(from: text)
    }

    /// Offline-only: splits OCR text into multiple medications (clinic table + diagnosis context).
    func parseMany(from text: String) -> [ParsedMedication] {
        let condition = Self.extractCondition(from: text)
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let blocks = Self.segmentMedicationBlocks(lines: lines)
        var results: [ParsedMedication] = []
        for block in blocks {
            if let row = Self.parseMedicationBlock(block, defaultCondition: condition),
               !row.drug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(row)
            }
        }

        if results.isEmpty {
            let legacy = parse(from: text)
            if !legacy.drug.isEmpty || !legacy.dose.isEmpty || !legacy.times.isEmpty {
                var one = legacy
                if one.condition.isEmpty { one.condition = condition }
                return [one]
            }
        }

        return results
    }

    /// Original single-block heuristic (voice / short notes).
    func parse(from text: String) -> ParsedMedication {
        var result = ParsedMedication()
        let lower = text.lowercased()

        if let match = text.firstMatch(of: /([A-Z][a-z]+(?:\s[A-Z][a-z]+)?)\s*\d+\s*mg/) {
            result.drug = String(match.1)
        }

        if let match = text.firstMatch(of: /(\d+(?:\.\d+)?\s*(?:mg|mcg|ml|g|units?))/) {
            result.dose = String(match.1)
        }

        if lower.contains("morning") || lower.contains("once daily") {
            result.times.append("08:00")
        }
        if lower.contains("evening") || lower.contains("night") {
            result.times.append("20:00")
        }
        if lower.contains("twice daily") || lower.contains("bid") {
            result.times = ["08:00", "20:00"]
        }

        if let match = text.firstMatch(of: /(?:for|treatment of)\s+([\w\s]+?)(?:\.|,|\n|$)/) {
            result.condition = String(match.1).trimmingCharacters(in: .whitespaces)
        }

        return result
    }

    func medicationRequest(from text: String) -> MedicationRequest {
        let rows = parseMany(from: text)
        let first = rows.first ?? ParsedMedication()
        return MedicationRequest(
            drug: first.drug,
            dose: first.dose,
            times: first.times,
            condition: first.condition
        )
    }

    // MARK: - Multi-row prescription parsing

    private static func extractCondition(from text: String) -> String {
        if let m = text.firstMatch(of: /Principal\s+Diagnosis:\s*[\n\r]*\s*(.+)/.ignoresCase()) {
            return String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let m = text.firstMatch(of: /Primary\s+Diagnosis:\s*[\n\r]*\s*(.+)/.ignoresCase()) {
            return String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let m = text.firstMatch(of: /Principal\s+Diagnosis:\s*(.+)/.ignoresCase()) {
            return String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let m = text.firstMatch(of: /Secondary\s+Diagnosis:\s*([A-Z]\d{2}\.[^\n]+)/.ignoresCase()) {
            return String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func segmentMedicationBlocks(lines: [String]) -> [[String]] {
        var start = 0
        if let idx = lines.firstIndex(where: { $0.range(of: "medicine name", options: .caseInsensitive) != nil }) {
            start = min(idx + 1, lines.count)
        }

        var blocks: [[String]] = []
        var current: [String] = []

        for line in lines.dropFirst(start) {
            if looksLikeMedicineNameLine(line) {
                if !current.isEmpty { blocks.append(current) }
                current = [line]
            } else if !current.isEmpty {
                if shouldTerminateBlock(line) {
                    blocks.append(current)
                    current = []
                } else if current.count < 14 {
                    current.append(line)
                }
            }
        }
        if !current.isEmpty { blocks.append(current) }

        return blocks
    }

    private static func shouldTerminateBlock(_ line: String) -> Bool {
        let u = line.uppercased()
        if u.hasPrefix("DR.") || u.contains("SIGNATURE") || u.contains("REGISTRATION NO") { return true }
        if u.contains("THANK YOU") || u.contains("APPOINTMENT") { return true }
        return false
    }

    private static func looksLikeMedicineNameLine(_ line: String) -> Bool {
        let u = line.uppercased()
        if u.contains("DIAGNOSIS") || u.contains("PRINCIPAL DIAGNOSIS") || u.contains("SECONDARY DIAGNOSIS") { return false }
        if u.hasPrefix("WEIGHT") || u.hasPrefix("DR.") || u.contains("ERX REFERENCE") { return false }
        if u.contains("VISIT ID") || u.contains("PRESCRIPTION DATE") || u.contains("MEMBERSHIP") { return false }
        if u.contains("MEDICAL CENTRE") || u == "IFE" || u == "LIFE" { return false }
        if u == "STRENGTH" || u == "DOSAGE" || u == "FREQUENCY" || u == "DURATION" || u == "QTY" || u == "REMARKS" { return false }
        if u.contains("MEDICINE NAME") && u.count < 24 { return false }
        if u.range(of: #"^[A-Z]\d{2}\."#, options: .regularExpression) != nil { return false }
        if u.contains("EVERY ") && u.contains("HOUR") { return false }
        if u == "OD" || u == "BD" || u == "TDS" { return false }

        let tokens = [
            "TABLET", "TABLETS", "SACHET", "SACHETS", "POWDER", "FILM", "FILMS",
            "CAPSULE", "CAPSULES", "BLISTER", "PACK", "PACKS", "SOLUBLE", "DELAYED",
            "PACKET", "PACKETS", "GRANULE", "SUSPENSION", "SOLUTION", "INJECTION",
        ]
        if tokens.contains(where: { u.contains($0) }) && line.count >= 10 { return true }
        if line.range(of: #"\(\d+'S"#, options: .regularExpression) != nil && line.count >= 12 { return true }
        return false
    }

    private static func parseMedicationBlock(_ lines: [String], defaultCondition: String) -> ParsedMedication? {
        guard let first = lines.first else { return nil }
        var p = ParsedMedication()
        p.drug = cleanDrugLine(first)
        let blob = lines.joined(separator: "\n")
        p.dose = extractStrength(from: lines)
        if p.dose.isEmpty {
            p.dose = extractStrength(from: [blob])
        }
        let dosageNote = extractDosageNote(from: blob)
        if !dosageNote.isEmpty {
            p.dose = p.dose.isEmpty ? dosageNote : "\(p.dose) · \(dosageNote)"
        }
        p.times = extractSchedule(from: blob)
        p.condition = defaultCondition
        return p
    }

    private static func cleanDrugLine(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: #"\s+\d{4}-\d{6}-\d{4}$"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractStrength(from lines: [String]) -> String {
        let mgPattern = /\d+(?:\.\d+)?\s*mg\b/.ignoresCase()
        for line in lines {
            if line.uppercased().contains("BILLION") {
                let trimmed = line.replacingOccurrences(of: "|", with: " ").split(separator: " ").prefix(8).joined(separator: " ")
                if !trimmed.isEmpty { return String(trimmed) }
            }
            if let m = line.firstMatch(of: mgPattern) {
                return String(m.0).replacingOccurrences(of: "MG", with: "mg")
            }
        }
        return ""
    }

    private static func extractDosageNote(from blob: String) -> String {
        if let m = blob.firstMatch(of: /(\d+)\s*\/\s*(Sachet|tablet|tablets|capsule|capsules)/.ignoresCase()) {
            return "\(m.1)/\(String(m.2).lowercased())"
        }
        return ""
    }

    private static func extractSchedule(from blob: String) -> [String] {
        let u = blob.uppercased()
        if u.range(of: #"\bOD\b"#, options: .regularExpression) != nil
            || u.contains("ONCE DAILY")
            || u.contains(" EVERY DAY") {
            return ["08:00"]
        }
        if u.contains("BID") || u.contains("TWICE DAILY") {
            return ["08:00", "20:00"]
        }
        if u.contains("TDS") || u.contains("THREE TIMES") {
            return ["08:00", "14:00", "20:00"]
        }
        if let m = blob.firstMatch(of: /EVERY\s+(\d+)\s*HOURS?/.ignoresCase()) {
            let h = Int(String(m.1)) ?? 8
            return scheduleForEveryHours(h)
        }
        return []
    }

    private static func scheduleForEveryHours(_ hours: Int) -> [String] {
        switch hours {
        case 6:
            return ["06:00", "12:00", "18:00"]
        case 8:
            return ["06:00", "14:00", "22:00"]
        case 12:
            return ["08:00", "20:00"]
        case 24:
            return ["08:00"]
        default:
            guard hours > 0, hours < 24 else { return [] }
            var times: [String] = []
            var minute = 0
            while minute < 24 * 60 {
                let h = minute / 60
                let m = minute % 60
                times.append(String(format: "%02d:%02d", h, m))
                minute += hours * 60
            }
            return times.isEmpty ? [] : times
        }
    }
}
