//
//  SettingsView.swift
//  MemoryMate
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @StateObject private var vm = SettingsVM()
    @FocusState private var piIPFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tailscale IP", text: $vm.piIP)
                        .textContentType(.none)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .keyboardType(.numbersAndPunctuation)
                        .focused($piIPFieldFocused)

                    Button("Test connection") {
                        piIPFieldFocused = false
                        Task { await vm.testConnection() }
                    }

                    LabeledContent("Status") {
                        statusLabel
                    }
                } header: {
                    Text("Pi connection")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enter the Rubik Pi Tailscale IP. The app uses port 8000 on your tailnet.")
                        if vm.connectionStatus == .offline, let lastError = vm.lastError {
                            Text(lastError)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { piIPFieldFocused = false }
                }
            }
            #endif
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch vm.connectionStatus {
        case .untested:
            Text("Not tested").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                Text("Checking…")
            }
        case .online:
            Label("Online", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .offline:
            Label("Offline", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
