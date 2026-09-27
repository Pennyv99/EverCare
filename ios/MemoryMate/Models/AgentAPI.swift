//
//  AgentAPI.swift
//  MemoryMate
//

import Foundation

struct AgentAPIRequest: Encodable {
    let query: String
    let timeout: Int?
}

struct AgentAPIResponse: Decodable {
    let query: String
    let response: String
    let status: String
    let error: String?
}

struct HealthResponse: Decodable {
    let status: String
    let camera: Bool
    let mic: Bool
    let speaker: Bool
}
