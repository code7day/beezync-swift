import Foundation

final class MockURLProtocol: URLProtocol {
    struct Captured {
        let method: String
        let path: String
        let headers: [String: String]
        let body: [String: Any]
    }

    nonisolated(unsafe) static var handler: ((Captured) -> (Int, Data))?
    nonisolated(unsafe) static var captured: [Captured] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        captured = []
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            var acc = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                acc.append(buf, count: n)
            }
            stream.close()
            data = acc
        }
        let body = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let cap = Captured(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        MockURLProtocol.lock.lock()
        MockURLProtocol.captured.append(cap)
        let h = MockURLProtocol.handler
        MockURLProtocol.lock.unlock()
        let (status, payload) = h?(cap) ?? (200, Data("{}".utf8))
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
