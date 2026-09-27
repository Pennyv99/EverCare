//
//  MedicationFormPresets.swift
//  MemoryMate
//

import Foundation

enum MedicationFormPresets {
    static let conditionSuggestions: [String] = [
        "Blood pressure",
        "Before food",
        "After food",
        "With food",
        "Diabetes",
        "Heart health",
        "Cholesterol",
        "Pain",
        "Inflammation",
        "Sleep",
        "Anxiety",
        "As needed",
    ]

    static let doseUnits: [String] = [
        "mg", "mcg", "g",
        "ml", "L",
        "IU",
        "tablet", "tablets",
        "capsule", "capsules",
        "sachet", "sachets",
        "drop", "drops",
        "puff", "puffs",
        "units",
        "spray", "sprays",
    ]

    /// Split "40 mg" / "1 tablet" into amount + unit tail when possible.
    static func splitDoseString(_ dose: String) -> (amount: String, unitTail: String) {
        let d = dose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return ("", "") }
        if d.contains("|") || d.contains("\n") { return ("", d) }
        let parts = d.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return ("", d) }
        let firstStr = String(first)
        if Double(firstStr) != nil, parts.count == 2 {
            return (firstStr, String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let m = d.firstMatch(of: /^(\d+(?:\.\d+)?)\s+(.+)$/) {
            return (String(m.1), String(m.2).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ("", d)
    }

    static func normalizedUnit(from raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hit = doseUnits.first(where: { $0.lowercased() == t }) { return hit }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
