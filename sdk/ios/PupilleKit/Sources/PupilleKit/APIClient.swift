import Foundation

/// JSON over HTTP(S) to the backend's `/v1` routes.
struct APIClient {
    let baseURL: URL
    let session: URLSession

    private struct APIError: Decodable { let error: String }

    func url(_ path: String) throws -> URL {
        guard let scheme = baseURL.scheme, ["http", "https"].contains(scheme), baseURL.host != nil else {
            throw PupilleError.invalidBackendURL
        }
        return baseURL.appending(path: path)
    }

    func get<T: Decodable>(_ path: String, headers: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: try url(path))
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return try decode(data, response)
    }

    func post<T: Decodable>(_ path: String, _ body: [String: Any], headers: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: try url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        return try decode(data, response)
    }

    /// Exact bytes, never re-encoded, so the hash check sees what the server stored.
    func bytes(_ path: String) async throws -> Data? {
        let (data, response) = try await session.data(from: url(path))
        return (response as? HTTPURLResponse)?.statusCode == 200 ? data : nil
    }

    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw PupilleError.invalidResponse }
        if !(200..<300).contains(http.statusCode) {
            switch (try? JSONDecoder().decode(APIError.self, from: data))?.error {
            case "human_already_registered": throw PupilleError.humanAlreadyRegistered
            case "handle_taken": throw PupilleError.handleTaken
            case let code?: throw PupilleError.server(code)
            case nil: throw PupilleError.server("HTTP \(http.statusCode)")
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
