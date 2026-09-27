//
//  MedConfirmItemView.swift
//  MemoryMate
//

import SwiftUI

struct MedConfirmItemView: View {
    @ObservedObject var vm: MedicationVM
    let index: Int

    var body: some View {
        Group {
            if vm.importItems.indices.contains(index) {
                MedicationRequestEditor(item: itemBinding)
                    .id(index)
                    .navigationTitle("Medication \(index + 1)")
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("Missing row", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private var itemBinding: Binding<MedicationRequest> {
        Binding(
            get: {
                guard vm.importItems.indices.contains(index) else {
                    return MedicationRequest(drug: "", dose: "", times: [], condition: "")
                }
                return vm.importItems[index]
            },
            set: { vm.replaceImportItem(at: index, with: $0) }
        )
    }
}
