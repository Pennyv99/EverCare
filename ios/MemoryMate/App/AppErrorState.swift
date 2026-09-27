//
//  AppErrorState.swift
//  MemoryMate
//

import Combine
import Foundation

@MainActor
final class AppErrorState: ObservableObject {
    @Published var message: String?

    func present(_ error: Error) {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            message = description
        } else {
            message = error.localizedDescription
        }
    }

    func clear() {
        message = nil
    }
}
