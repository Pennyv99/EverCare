//
//  ContentView.swift
//  MemoryMate
//

import SwiftUI

struct ContentView: View {
    @StateObject private var appError = AppErrorState()

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            FaceEnrollmentView()
                .tabItem { Label("People", systemImage: "person.badge.plus") }

            MedEntryView()
                .tabItem { Label("Medications", systemImage: "pill.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .environmentObject(appError)
        .alert("Error", isPresented: Binding(
            get: { appError.message != nil },
            set: { if !$0 { appError.clear() } }
        )) {
            Button("OK") { appError.clear() }
        } message: {
            Text(appError.message ?? "")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppErrorState())
}
