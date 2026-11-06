import Foundation

enum SocketError: Error {
    case closed(code: Int?)
}

protocol SocketConnection: AnyObject, Sendable {
    func open()
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

final class URLSessionSocket: SocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession) {
        task = session.webSocketTask(with: url)
    }

    func open() {
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let s): return s
            case .data(let d): return String(decoding: d, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            let code = task.closeCode.rawValue
            throw SocketError.closed(code: code == 0 ? nil : code)
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

struct HTTPClient: Sendable {
    let config: BeezyncConfiguration
    let session: URLSession

    func send<B: Encodable>(_ method: String, _ path: String, body: B) async throws {
        var req = URLRequest(url: config.endpoint(path))
        req.httpMethod = method
        req.setValue("Bearer \(config.publicKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw BeezyncError.network((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw BeezyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw BeezyncError.http(status: http.statusCode, code: obj?["code"] as? String, message: obj?["error"] as? String)
        }
    }
}
