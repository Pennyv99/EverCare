//
//  MedicationListView.swift
//  MemoryMate
//

import SwiftUI

struct MedicationListView: View {
    let medications: [Medication]
    let reload: () async -> Void

    @EnvironmentObject private var appError: AppErrorState

    var body: some View {
        List {
            ForEach(medications) { medication in
                VStack(alignment: .leading, spacing: 6) {
                    Text(medication.drug)
                        .font(.headline)
                    HStack {
                        Text(medication.dose)
                        if !medication.times.isEmpty {
                            Text(medication.times.joined(separator: ", "))
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if !medication.condition.isEmpty {
                        Text(medication.condition)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                Task {
                    for index in offsets {
                        let item = medications[index]
                        do {
                            try await APIService.shared.delete("/medication/\(item.id)")
                            await reload()
                        } catch {
                            appError.present(error)
                        }
                    }
                }
            }
        }
        .overlay {
            if medications.isEmpty {
                ContentUnavailableView(
                    "No medications",
                    systemImage: "pills",
                    description: Text("Add medications from the Medications tab.")
                )
            }
        }
        .refreshable { await reload() }
    }
}
