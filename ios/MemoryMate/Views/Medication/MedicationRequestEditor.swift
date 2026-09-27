//
//  MedicationRequestEditor.swift
//  MemoryMate
//

import SwiftUI

struct MedicationRequestEditor: View {
    @Binding var item: MedicationRequest

    @State private var doseAmount: String = ""
    @State private var doseUnit: String = "mg"
    @State private var doseStructured = true
    @State private var didHydrate = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MMSectionTitle(text: "Medication")
                MMGlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Drug name")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("e.g. Pantor 40", text: drugBinding)
                            .font(.body.weight(.medium))
                            .foregroundStyle(MedicationFormTheme.inputText)
                            .padding(14)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(MedicationFormTheme.inputBackground)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(MedicationFormTheme.inputBorder, lineWidth: 1)
                            }
                    }
                }

                MMSectionTitle(text: "Dose")
                MMGlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Dose style", selection: $doseStructured) {
                            Text("Amount + unit").tag(true)
                            Text("Free text").tag(false)
                        }
                        .pickerStyle(.segmented)

                        if doseStructured {
                            TextField("Amount", text: $doseAmount)
                                .keyboardType(.decimalPad)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(MedicationFormTheme.inputText)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                .background {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(MedicationFormTheme.inputBackground)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(MedicationFormTheme.inputBorder, lineWidth: 1)
                                }
                                .onChange(of: doseAmount) { _, _ in commitStructuredDose() }

                            Text("Unit")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(MedicationFormPresets.doseUnits, id: \.self) { unit in
                                        MMChoiceChip(title: unit, isSelected: doseUnit.caseInsensitiveCompare(unit) == .orderedSame) {
                                            doseUnit = unit
                                            commitStructuredDose()
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }

                            TextField("Custom unit (e.g. mL/kg)", text: $doseUnit)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.footnote)
                                .foregroundStyle(MedicationFormTheme.inputText)
                                .padding(12)
                                .background {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(MedicationFormTheme.inputBackground)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(MedicationFormTheme.inputBorder, lineWidth: 1)
                                }
                                .onChange(of: doseUnit) { _, _ in commitStructuredDose() }

                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("Saving as:")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Text(previewStructuredDose())
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(MedicationFormTheme.accentDeep)
                            }
                            .padding(.top, 4)
                        } else {
                            TextField("e.g. 195 mg | 345 mg (complex strengths)", text: doseFreeBinding, axis: .vertical)
                                .lineLimit(4...10)
                                .font(.body)
                                .foregroundStyle(MedicationFormTheme.inputText)
                                .padding(14)
                                .background {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(MedicationFormTheme.inputBackground)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(MedicationFormTheme.inputBorder, lineWidth: 1)
                                }
                        }
                    }
                }

                MMSectionTitle(text: "Condition & notes")
                MMGlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Quick picks (tap to add)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 118), spacing: 10, alignment: .leading)],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(MedicationFormPresets.conditionSuggestions, id: \.self) { phrase in
                                MMPresetChip(title: phrase) {
                                    appendConditionPhrase(phrase)
                                }
                            }
                        }

                        Text("Custom text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("Type or combine with picks above", text: conditionBinding, axis: .vertical)
                            .lineLimit(2...6)
                            .foregroundStyle(MedicationFormTheme.inputText)
                            .padding(14)
                            .background {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(MedicationFormTheme.inputBackground)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(MedicationFormTheme.inputBorder, lineWidth: 1)
                            }
                    }
                }

                MMSectionTitle(text: "Schedule")
                MMGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(item.times.indices, id: \.self) { idx in
                            HStack(spacing: 12) {
                                Image(systemName: "clock")
                                    .foregroundStyle(MedicationFormTheme.accent)
                                TextField("HH:MM", text: Binding(
                                    get: { item.times[idx] },
                                    set: { new in
                                        var next = item
                                        next.times[idx] = new
                                        item = next
                                    }
                                ))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(MedicationFormTheme.inputText)
                                Spacer(minLength: 0)
                                Button(role: .destructive) {
                                    var next = item
                                    next.times.remove(at: idx)
                                    item = next
                                } label: {
                                    Image(systemName: "trash.circle.fill")
                                        .symbolRenderingMode(.hierarchical)
                                }
                                .accessibilityLabel("Remove time")
                            }
                            .padding(.vertical, 6)
                            if idx < item.times.count - 1 {
                                Divider().opacity(0.35)
                            }
                        }

                        Button {
                            var next = item
                            next.times.append("08:00")
                            item = next
                        } label: {
                            Label("Add time", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MedicationFormTheme.accent)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollContentBackground(.hidden)
        .background {
            MedicationFormTheme.pageGradient
                .ignoresSafeArea()
        }
        .onAppear {
            if !didHydrate {
                initialHydrate()
                didHydrate = true
            }
        }
    }

    private var drugBinding: Binding<String> {
        Binding(
            get: { item.drug },
            set: { v in
                var n = item
                n.drug = v
                item = n
            }
        )
    }

    private var conditionBinding: Binding<String> {
        Binding(
            get: { item.condition },
            set: { v in
                var n = item
                n.condition = v
                item = n
            }
        )
    }

    private var doseFreeBinding: Binding<String> {
        Binding(
            get: { item.dose },
            set: { v in
                var n = item
                n.dose = v
                item = n
            }
        )
    }

    private func appendConditionPhrase(_ phrase: String) {
        var c = item.condition.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.localizedCaseInsensitiveContains(phrase) { return }
        if c.isEmpty {
            c = phrase
        } else {
            c += ", " + phrase
        }
        var n = item
        n.condition = c
        item = n
    }

    private func previewStructuredDose() -> String {
        let amt = doseAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        if amt.isEmpty { return "—" }
        return "\(amt) \(doseUnit)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitStructuredDose() {
        guard doseStructured else { return }
        let amt = doseAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        var n = item
        if amt.isEmpty {
            n.dose = ""
        } else {
            n.dose = "\(amt) \(doseUnit)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        item = n
    }

    private func initialHydrate() {
        let d = item.dose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else {
            doseAmount = ""
            doseUnit = "mg"
            doseStructured = true
            return
        }
        if d.contains("|") || d.contains("\n") || d.count > 56 {
            doseStructured = false
            return
        }
        let (a, tail) = MedicationFormPresets.splitDoseString(d)
        if a.isEmpty {
            doseStructured = false
        } else {
            doseStructured = true
            doseAmount = a
            if let hit = MedicationFormPresets.doseUnits.first(where: { tail.caseInsensitiveCompare($0) == .orderedSame }) {
                doseUnit = hit
            } else if tail.isEmpty {
                doseUnit = "mg"
            } else {
                doseUnit = tail
            }
        }
    }
}
