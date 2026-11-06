import XCTest
@testable import BeezyncSDK

final class LiveEngineTests: XCTestCase {
    private struct Env {
        let baseUrl: String, appId: String, publicKey: String, secretKey: String
    }

    private func env() throws -> Env {
        let e = ProcessInfo.processInfo.environment
        guard e["BEEZYNC_LIVE"] == "1" else { throw XCTSkip("Set BEEZYNC_LIVE=1 to run against a real engine") }
        guard let b = e["BASE_URL"], let a = e["APP_ID"], let p = e["PUBLIC_KEY"], let s = e["SECRET_KEY"] else {
            throw XCTSkip("BASE_URL, APP_ID, PUBLIC_KEY and SECRET_KEY are required")
        }
        return Env(baseUrl: b, appId: a, publicKey: p, secretKey: s)
    }

    private func secretCall(_ env: Env, _ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: env.baseUrl + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(env.secretKey)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((resp as! HTTPURLResponse).statusCode, obj)
    }

    private func next(_ stream: AsyncStream<BeezyncMessage>, timeout: TimeInterval = 8, where match: @escaping @Sendable (BeezyncMessage) -> Bool) async -> BeezyncMessage? {
        await withTaskGroup(of: BeezyncMessage?.self) { group in
            group.addTask {
                for await m in stream where match(m) { return m }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func testFullFlow() async throws {
        let env = try env()
        let cfg = try XCTUnwrap(BeezyncConfiguration(appId: env.appId, publicKey: env.publicKey, baseUrl: env.baseUrl))
        let client = BeezyncClient(configuration: cfg)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let user = "swift-sdk-\(suffix)"
        let token = "swift-sdk-token-\(suffix)"
        let channel = "swift-sdk-\(suffix)"

        try await client.registerDevice(token: token, externalUserId: user, platform: "ios", tags: ["suite": "swift"])
        try await client.setUser(user)

        let stream = await client.messages()
        let events = await client.events()
        await client.subscribe(channel)
        await client.connect()

        var subscribed = false
        for await e in events {
            if case .subscribed(let c) = e, c == channel { subscribed = true; break }
        }
        XCTAssertTrue(subscribed)

        let (pubStatus, pub) = try await secretCall(env, "POST", "/v1/api/publish", body: ["channel": channel, "event": "swift.test", "data": ["hello": "world"]])
        XCTAssertEqual(pubStatus, 200, "\(pub)")
        let published = await next(stream) { $0.kind == .published && $0.event == "swift.test" }
        XCTAssertEqual(published?.channel, channel)
        XCTAssertEqual(published?.data?["hello"], "world")

        let (pushStatus, push) = try await secretCall(env, "POST", "/v1/api/send-push", body: [
            "title": "Swift title", "body": "Swift body", "target_type": "broadcast", "transport": "ws"
        ])
        XCTAssertEqual(pushStatus, 202, "\(push)")
        let pushId = try XCTUnwrap(push["id"] as? String)
        let notification = await next(stream) { $0.kind == .notification && $0.title == "Swift title" }
        XCTAssertNotNil(notification, "ws notification did not arrive")

        try await client.trackReceived(pushId)
        try await client.trackClicked(pushId)

        var counters: [String: Any] = [:]
        for _ in 0..<10 {
            let (st, obj) = try await secretCall(env, "GET", "/v1/api/notifications/\(pushId)")
            XCTAssertEqual(st, 200, "\(obj)")
            counters = obj
            if (obj["received"] as? Int ?? 0) >= 1 && (obj["clicked"] as? Int ?? 0) >= 1 { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertEqual(counters["received"] as? Int, 1, "\(counters)")
        XCTAssertEqual(counters["clicked"] as? Int, 1, "\(counters)")

        await client.disconnect()
        try await client.unregisterDevice()
    }
}
