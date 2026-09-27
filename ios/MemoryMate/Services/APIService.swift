//
//  APIService.swift
//  MemoryMate
//

import Foundation
import UIKit

actor APIService {
    static let shared = APIService()

    private let session = URLSession.shared

    private var baseURLString: String {
        let ip = UserDefaults.standard.string(forKey: "piIP") ?? ""
        guard !ip.isEmpty else { return "" }
        return "http://\(ip):8000"
    }

    private func makeURL(_ path: String) throws -> URL {
        let base = baseURLString
        guard !base.isEmpty else { throw APIError.piUnreachable }
        guard let url = URL(string: base + path) else { throw APIError.invalidURL }
        return url
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        let url = try makeURL(path)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(from: url)
        } catch {
            throw APIError.networkFailure(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.httpError(0)
        }
        guard http.statusCode == 200 else {
            throw APIError.httpError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailure
        }
    }

    func post<B: Encodable, R: Decodable>(_ path: String, body: B) async throws -> R {
        let url = try makeURL(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.networkFailure(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.httpError(0)
        }
        guard http.statusCode == 200 else {
            throw APIError.httpError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw APIError.decodingFailure
        }
    }

    func delete(_ path: String) async throws {
        let url = try makeURL(path)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let (_, resp): (Data, URLResponse)
        do {
            (_, resp) = try await session.data(for: req)
        } catch {
            throw APIError.networkFailure(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.httpError(0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpError(http.statusCode)
        }
    }

    /// POST JSON, return raw body (e.g. MP3 from `/agent-voice`).
    func postReturningData<B: Encodable>(_ path: String, body: B) async throws -> Data {
        let url = try makeURL(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.networkFailure(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.httpError(0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpError(http.statusCode)
        }
        return data
    }

    func enrollFace(name: String, relation: String, images: [UIImage]) async throws {
        let url = try makeURL("/enroll-face")
        let boundary = UUID().uuidString
        var body = Data()

        for (key, val) in [("name", name), ("relation", relation)] {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.append("\(val)\r\n")
        }

        for (i, img) in images.enumerated() {
            guard let jpeg = img.jpegData(compressionQuality: 0.85) else { continue }
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"files\"; filename=\"photo_\(i).jpg\"\r\n")
            body.append("Content-Type: image/jpeg\r\n\r\n")
            body.append(jpeg)
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (_, resp): (Data, URLResponse)
        do {
            (_, resp) = try await session.data(for: req)
        } catch {
            throw APIError.networkFailure(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.httpError(0)
        }
        guard http.statusCode == 200 else {
            throw APIError.httpError(http.statusCode)
        }
    }
}
