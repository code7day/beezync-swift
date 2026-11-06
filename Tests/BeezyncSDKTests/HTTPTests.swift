import XCTest
@testable import BeezyncSDK

final class HTTPTests: XCTestCase {
    private func makeClient() -> BeezyncClient {
        MockURLProtocol.reset()
        let cfg = BeezyncConfiguration(appId: "app-1", publicKey: "pk_test", baseUrl: URL(string: "https://api.example.com")!)
        return BeezyncClient(configuration: cfg, session: MockURLProtocol.session())
    }

    func testRegisterDeviceRequest() async throws {
        let client = makeClient()
        try await client.registerDevice(token: "fcm-token", externalUserId: "u1", platform: "ios")
        let req = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/api/register-device")
        XCTAssertEqual(req.headers["Authorization"], "Bearer pk_test")
        XCTAssertEqual(req.body["token"] as? String, "fcm-token")
        XCTAssertEqual(req.body["platform"] as? String, "ios")
        XCTAssertEqual(req.body["external_user_id"] as? String, "u1")
        XCTAssertEqual(MockURLProtocol.captured.count, 1)
    }

    func testRegisterWithTagsPatches() async throws {
        let client = makeClient()
        try await client.registerDevice(token: "t", tags: ["plan": "pro", "n": 3])
        XCTAssertEqual(MockURLProtocol.captured.map(\.method), ["POST", "PATCH"])
        let patch = MockURLProtocol.captured[1]
        XCTAssertEqual(patch.path, "/v1/api/devices")
        XCTAssertEqual(patch.body["token"] as? String, "t")
        let tags = try XCTUnwrap(patch.body["tags"] as? [String: Any])
        XCTAssertEqual(tags["plan"] as? String, "pro")
        XCTAssertEqual(tags["n"] as? Int, 3)
    }

    func testSetUserAndUnregister() async throws {
        let client = makeClient()
        do {
            try await client.setUser("u")
            XCTFail("expected notRegistered")
        } catch {
            XCTAssertEqual(error as? BeezyncError, .notRegistered)
        }
        try await client.registerDevice(token: "t")
        try await client.setUser("u9")
        try await client.unregisterDevice()
        let last = MockURLProtocol.captured.suffix(2)
        XCTAssertEqual(last.first?.body["external_user_id"] as? String, "u9")
        XCTAssertEqual(last.last?.path, "/v1/api/unregister-device")
        XCTAssertEqual(last.last?.body["token"] as? String, "t")
    }

    func testTrackEvents() async throws {
        let client = makeClient()
        try await client.registerDevice(token: "tok")
        try await client.trackReceived("n1")
        try await client.trackClicked("n1")
        try await client.trackDismissed("n1")
        let evs = MockURLProtocol.captured.suffix(3)
        XCTAssertEqual(evs.map { $0.body["event"] as? String }, ["received", "clicked", "dismissed"])
        XCTAssertTrue(evs.allSatisfy { $0.path == "/v1/api/notification-events" && $0.body["notification_id"] as? String == "n1" && $0.body["token"] as? String == "tok" })
    }

    func testHTTPErrorMapping() async {
        let client = makeClient()
        MockURLProtocol.handler = { _ in (404, Data(#"{"error":"not found","code":"not_found"}"#.utf8)) }
        do {
            try await client.trackReceived("zz")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? BeezyncError, .http(status: 404, code: "not_found", message: "not found"))
        }
    }
}
