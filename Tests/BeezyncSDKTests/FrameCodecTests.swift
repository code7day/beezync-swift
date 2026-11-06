import XCTest
@testable import BeezyncSDK

final class FrameCodecTests: XCTestCase {
    private func obj(_ s: String) -> [String: String] {
        try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: String]
    }

    func testEncodeSubscribeWithAuth() {
        let s = FrameCodec.encode(.subscribe(channel: "private-a", auth: "abc", token: nil))
        XCTAssertEqual(obj(s), ["action": "subscribe", "channel": "private-a", "auth": "abc"])
    }

    func testEncodeSubscribeWithToken() {
        let s = FrameCodec.encode(.subscribe(channel: "x", auth: nil, token: "tok"))
        XCTAssertEqual(obj(s), ["action": "subscribe", "channel": "x", "token": "tok"])
    }

    func testEncodePublicSubscribeOmitsCredentials() {
        let s = FrameCodec.encode(.subscribe(channel: "news", auth: "", token: nil))
        XCTAssertEqual(obj(s), ["action": "subscribe", "channel": "news"])
    }

    func testEncodeUnsubscribeAndPing() {
        XCTAssertEqual(obj(FrameCodec.encode(.unsubscribe(channel: "x"))), ["action": "unsubscribe", "channel": "x"])
        XCTAssertEqual(FrameCodec.encode(.ping), "{\"action\":\"ping\"}")
    }

    func testDecodeConnectionEstablished() {
        let f = FrameCodec.decode(#"{"event":"connection_established","data":{"socket_id":"s-1"}}"#)
        XCTAssertEqual(f, .connectionEstablished(socketId: "s-1"))
    }

    func testDecodeConnectionEstablishedStringData() {
        let f = FrameCodec.decode(#"{"event":"connection_established","data":"{\"socket_id\":\"s-2\"}"}"#)
        XCTAssertEqual(f, .connectionEstablished(socketId: "s-2"))
    }

    func testDecodeSubscriptionFrames() {
        XCTAssertEqual(FrameCodec.decode(#"{"event":"subscription_succeeded","channel":"a"}"#), .subscriptionSucceeded(channel: "a"))
        XCTAssertEqual(FrameCodec.decode(#"{"event":"subscription_error","channel":"a","error":"denied"}"#), .subscriptionError(channel: "a", error: "denied"))
        XCTAssertEqual(FrameCodec.decode(#"{"event":"pong"}"#), .pong)
    }

    func testDecodePublishedMessage() {
        let f = FrameCodec.decode(#"{"event":"order.created","channel":"orders","data":{"n":5,"ok":true},"id":"m1","ts":1700000000}"#)
        guard case .message(let m) = f else { return XCTFail() }
        XCTAssertEqual(m.kind, .published)
        XCTAssertEqual(m.event, "order.created")
        XCTAssertEqual(m.channel, "orders")
        XCTAssertEqual(m.id, "m1")
        XCTAssertEqual(m.data, ["n": 5, "ok": true])
        XCTAssertEqual(m.timestamp, 1700000000)
    }

    func testDecodeNotification() {
        let f = FrameCodec.decode(#"{"id":"n1","title":"Hi","body":"There","channel":"c","data":{"k":"v"}}"#)
        guard case .message(let m) = f else { return XCTFail() }
        XCTAssertEqual(m.kind, .notification)
        XCTAssertEqual(m.id, "n1")
        XCTAssertEqual(m.title, "Hi")
        XCTAssertEqual(m.body, "There")
        XCTAssertNil(m.event)
        XCTAssertEqual(m.data?["k"], "v")
    }

    func testDecodeGarbage() {
        XCTAssertNil(FrameCodec.decode("not json"))
        XCTAssertNil(FrameCodec.decode("[1,2]"))
        XCTAssertNil(FrameCodec.decode(#"{"foo":1}"#))
    }

    func testWebSocketUrl() {
        let c = BeezyncConfiguration(appId: "app", publicKey: "pk_1", baseUrl: URL(string: "https://api.example.com/")!)
        XCTAssertEqual(c.webSocketUrl.absoluteString, "wss://api.example.com/v1/ws?app_id=app&key=pk_1")
        let l = BeezyncConfiguration(appId: "app", publicKey: "pk_1", baseUrl: URL(string: "http://127.0.0.1:8099")!)
        XCTAssertEqual(l.webSocketUrl.absoluteString, "ws://127.0.0.1:8099/v1/ws?app_id=app&key=pk_1")
    }

    func testPushPayloadHelper() {
        XCTAssertEqual(BeezyncPush.notificationId(from: ["bz_id": "abc"]), "abc")
        XCTAssertEqual(BeezyncPush.notificationId(from: ["data": ["bz_id": "def"]]), "def")
        XCTAssertEqual(BeezyncPush.notificationId(from: ["data": #"{"bz_id":"ghi"}"#]), "ghi")
        XCTAssertNil(BeezyncPush.notificationId(from: ["bz_id": "  "]))
        XCTAssertNil(BeezyncPush.notificationId(from: ["aps": ["alert": "x"]]))
    }
}
