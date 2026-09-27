//
//  Medication.swift
//  MemoryMate
//

import Foundation

struct Medication: Identifiable, Codable, Hashable {
    /// Mongo ObjectId string (`_id` or `id` in JSON depending on FastAPI/Pydantic settings).
    let id: String
    let drug: String
    let dose: String
    let times: [String]
    let condition: String

    enum CodingKeys: String, CodingKey {
        case idPlain = "id"
        case idMongo = "_id"
        case drug, dose, times, condition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let mongo = try c.decodeIfPresent(String.self, forKey: .idMongo) {
            id = mongo
        } else {
            id = try c.decode(String.self, forKey: .idPlain)
        }
        drug = try c.decode(String.self, forKey: .drug)
        dose = try c.decode(String.self, forKey: .dose)
        times = try c.decode([String].self, forKey: .times)
        condition = try c.decode(String.self, forKey: .condition)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .idMongo)
        try c.encode(drug, forKey: .drug)
        try c.encode(dose, forKey: .dose)
        try c.encode(times, forKey: .times)
        try c.encode(condition, forKey: .condition)
    }
}

struct MedicationRequest: Codable, Hashable {
    var drug: String
    var dose: String
    var times: [String]
    var condition: String
}
