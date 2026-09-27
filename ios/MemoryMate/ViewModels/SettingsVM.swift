//
//  SettingsVM.swift
//  MemoryMate
//

import Combine
import Foundation

@MainActor
final class SettingsVM: ObservableObject {
    @Published var piIP: String {
        didSet { UserDefaults.standard.set(piIP, forKey: "piIP") }
    }

    @Published private(set) var connectionStatus: ConnectionStatus = .untested
    @Published private(set) var lastError: String?

    enum ConnectionStatus {
        case untested
        case checking
        case online
        case offline
    }

    init() {
        self.piIP = UserDefaults.standard.string(forKey: "piIP") ?? ""
    }

    func testConnection() async {
        connectionStatus = .checking
        lastError = nil
        let ip = piIP.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[MemoryMate][Settings] testConnection ip=\(ip.isEmpty ? "(empty)" : ip) url=http://\(ip):8000/health")
        do {
            let _: HealthResponse = try await APIService.shared.get("/health")
            connectionStatus = .online
            print("[MemoryMate][Settings] testConnection ok")
        } catch {
            connectionStatus = .offline
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = text
            print("[MemoryMate][Settings] testConnection failed: \(text)")
        }
    }
}
