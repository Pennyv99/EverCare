//
//  MedicationFormTheme.swift
//  MemoryMate
//

import SwiftUI

enum MedicationFormTheme {
    static let cornerLarge: CGFloat = 22
    static let cornerChip: CGFloat = 20

    static let accent = Color(red: 0.20, green: 0.42, blue: 0.96)
    static let accentDeep = Color(red: 0.10, green: 0.22, blue: 0.55)
    static let violet = Color(red: 0.48, green: 0.36, blue: 0.98)
    static let inputBackground = Color(uiColor: .secondarySystemBackground)
    static let inputBorder = Color.primary.opacity(0.18)
    static let inputText = Color.primary

    /// Grouped-background tones only (no near-black corner) so footnotes and tab bar stay readable in dark mode.
    static var pageGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(uiColor: .systemGroupedBackground),
                Color(uiColor: .secondarySystemGroupedBackground),
                Color(uiColor: .systemGroupedBackground),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct MMGlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: MedicationFormTheme.cornerLarge, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: MedicationFormTheme.cornerLarge, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }
}

struct MMSectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

struct MMChoiceChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [MedicationFormTheme.accent, MedicationFormTheme.violet],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    } else {
                        Capsule(style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    }
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(isSelected ? 0 : 0.06), lineWidth: 1)
                }
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct MMPresetChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(MedicationFormTheme.accent.opacity(0.25), lineWidth: 1)
                }
                .foregroundStyle(MedicationFormTheme.accentDeep)
        }
        .buttonStyle(.plain)
    }
}
