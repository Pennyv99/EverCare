//
//  Person.swift
//  MemoryMate
//

import Foundation

struct Person: Identifiable, Codable, Hashable {
    /// MongoDB `ObjectId` string from `/enrolled-faces`.
    let id: String
    let name: String
    let relation: String
    /// Base64-encoded JPEG/PNG payloads from the server.
    let imageData: [String]
    /// Raw timestamp string from the API (ISO8601 or server-specific).
    let enrolledAtRaw: String?

    enum CodingKeys: String, CodingKey {
        case id, name, relation
        case imageData = "image_data"
        case enrolledAtRaw = "enrolled_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        relation = try c.decode(String.self, forKey: .relation)
        imageData = (try? c.decode([String].self, forKey: .imageData)) ?? []
        enrolledAtRaw = Self.decodeEnrolledAt(from: c)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(relation, forKey: .relation)
        try c.encode(imageData, forKey: .imageData)
        try c.encodeIfPresent(enrolledAtRaw, forKey: .enrolledAtRaw)
    }

    private static func decodeEnrolledAt(from c: KeyedDecodingContainer<CodingKeys>) -> String? {
        try? c.decode(String.self, forKey: .enrolledAtRaw)
    }
}
