//
//  MedEntryView.swift
//  MemoryMate
//

import SwiftUI

struct MedEntryView: View {
    @StateObject private var vm = MedicationVM()

    var body: some View {
        NavigationStack {
            MedPhotoView(vm: vm)
        }
    }
}
