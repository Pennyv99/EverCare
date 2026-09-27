//
//  APIError.swift
//  MemoryMate
//

import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case networkFailure(Error)
    case httpError(Int)
    case decodingFailure
    case piUnreachable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Pi address. Enter a valid IP in Settings."
        case .networkFailure(let error):
            return error.localizedDescription
        case .httpError(let code):
            return "Server returned HTTP \(code)."
        case .decodingFailure:
            return "Could not read the server response."
        case .piUnreachable:
            return "Cannot reach Pi. Check Tailscale IP."
        }
    }
}
