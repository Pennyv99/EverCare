//
//  MedConfirmListView.swift
//  MemoryMate
//

import SwiftUI

struct MedConfirmListView: View {
    @ObservedObject var vm: MedicationVM
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appError: AppErrorState

    @State private var isSavingAll = false

    private var allRowsHaveDrug: Bool {
        !vm.importItems.isEmpty
            && vm.importItems.allSatisfy { !$0.drug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        List {
            if vm.importItems.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No medications",
                        systemImage: "pills",
                        description: Text("Go back and run OCR again, or add a row manually.")
                    )
                    .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    ForEach(vm.importItems.indices, id: \.self) { index in
                        NavigationLink {
                            MedConfirmItemView(vm: vm, index: index)
                        } label: {
                            medicationRow(index: index)
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                                .padding(.vertical, 4)
                        )
                        .listRowSeparator(.hidden)
                    }
                    .onDelete(perform: vm.deleteImportItems)
                } header: {
                    Text("Medications (\(vm.importItems.count))")
                } footer: {
                    Text("Tap a row to edit. Save uploads every row to the Pi in order (local network only).")
                        .font(.footnote)
                        .foregroundStyle(Color(uiColor: .label).opacity(0.72))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background {
            MedicationFormTheme.pageGradient
                .ignoresSafeArea()
        }
        .navigationTitle("Confirm list")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Add row") {
                    vm.appendEmptyImportItem()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save all") {
                    Task { await saveAll() }
                }
                .disabled(!allRowsHaveDrug || isSavingAll || vm.importItems.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func medicationRow(index: Int) -> some View {
        let row = vm.importItems[index]
        VStack(alignment: .leading, spacing: 4) {
            Text(row.drug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled medication" : row.drug)
                .font(.headline)
                .foregroundStyle(row.drug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .primary)
            HStack {
                Text(row.dose.isEmpty ? "—" : row.dose)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(row.times.isEmpty ? "No times" : row.times.joined(separator: ", "))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func saveAll() async {
        isSavingAll = true
        defer { isSavingAll = false }
        do {
            try await vm.saveAllImported()
            vm.resetImportSession()
            dismiss()
        } catch {
            appError.present(error)
        }
    }
}
