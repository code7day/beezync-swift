import XCTest
@testable import BeezyncSDK

final class FakeSocket: SocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var sentFrames: [String] = []
    private var inbox: [Result<String, Error>] = []
    private var waiter: CheckedContinuation<String, Error>?
    private(set) var closed = false

    var sent: [String] {
        lock.lock(); defer { lock.unlock() }
        return sentFrames
    }

    func open() {}

    func send(_ text: String) async throws {
        lock.withLock { sentFrames.append(text) }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if !inbox.isEmpty {
                let r = inbox.removeFirst()
                lock.unlock()
                cont.resume(with: r)
            } else {
                waiter = cont
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
        push(.failure(SocketError.closed(code: nil)))
    }

    func push(_ r: Result<String, Error>) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(with: r)
        } else {
            inbox.append(r)
            lock.unlock()
        }
    }

    func server(_ text: String) { push(.success(text)) }
    func drop(code: Int?) { push(.failure(SocketError.closed(code: code))) }
}

final class SocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sockets: [FakeSocket] = []
    private(set) var urls: [URL] = []
    private(set) var delays: [TimeInterval] = []

    func make(_ url: URL) -> SocketConnection {
        let s = FakeSocket()
        lock.lock(); sockets.append(s); urls.append(url); lock.unlock()
        return s
    }

    func addDelay(_ d: TimeInterval) {
        lock.lock(); delays.append(d); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return sockets.count
    }

    func socket(_ i: Int) -> FakeSocket {
        lock.lock(); defer { lock.unlock() }
        return sockets[i]
    }
}

final class SocketTests: XCTestCase {
    private func make(box: SocketBox) -> BeezyncClient {
        let cfg = BeezyncConfiguration(appId: "app", publicKey: "pk", baseUrl: URL(string: "http://localhost:1")!)
        return BeezyncClient(
            configuration: cfg,
            session: .shared,
            socketFactory: { box.make($0) },
            sleep: { d in
                if d >= 3600 {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    return
                }
                box.addDelay(d)
                try? await Task.sleep(nanoseconds: 2_000_000)
            },
            random: { 0 },
            pingInterval: 3600
        )
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () async -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while await !cond() && Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private let hello = #"{"event":"connection_established","data":{"socket_id":"s1"}}"#

    func testResubscribeAfterDropAndBackoff() async throws {
        let box = SocketBox()
        let client = make(box: box)
        await client.subscribe("news")
        await client.subscribe("private-x", auth: "sig")
        await client.connect()
        await waitUntil { box.count >= 1 }
        box.socket(0).server(hello)
        await waitUntil { box.socket(0).sent.count >= 2 }
        XCTAssertEqual(box.socket(0).sent.count, 2)
        XCTAssertTrue(box.socket(0).sent.contains { $0.contains("\"channel\":\"news\"") })
        XCTAssertTrue(box.socket(0).sent.contains { $0.contains("\"auth\":\"sig\"") })

        box.socket(0).drop(code: 1006)
        await waitUntil { box.count >= 2 }
        box.socket(1).server(hello)
        await waitUntil { box.socket(1).sent.count >= 2 }
        XCTAssertEqual(box.socket(1).sent.count, 2)
        XCTAssertEqual(box.delays.first, 1)

        await client.unsubscribe("news")
        await waitUntil { box.socket(1).sent.count >= 3 }
        XCTAssertTrue(box.socket(1).sent.last!.contains("unsubscribe"))
        await client.disconnect()
    }

    func testCloseCode4200ReconnectsImmediately() async throws {
        let box = SocketBox()
        let client = make(box: box)
        await client.connect()
        await waitUntil { box.count >= 1 }
        box.socket(0).server(hello)
        await waitUntil { await client.isConnected }
        box.socket(0).drop(code: 4200)
        await waitUntil { box.count >= 2 }
        XCTAssertEqual(box.count, 2)
        XCTAssertTrue(box.delays.isEmpty)
        await client.disconnect()
    }

    func testMessageStreamAndEvents() async throws {
        let box = SocketBox()
        let client = make(box: box)
        let stream = await client.messages()
        let events = await client.events()
        await client.connect()
        await waitUntil { box.count >= 1 }
        let s = box.socket(0)
        s.server(hello)
        s.server(#"{"event":"subscription_succeeded","channel":"a"}"#)
        s.server(#"{"event":"pong"}"#)
        s.server(#"{"event":"e","channel":"a","data":{"x":1},"id":"1","ts":1}"#)
        s.server(#"{"id":"2","title":"T","body":"B"}"#)

        var got: [BeezyncMessage] = []
        for await m in stream {
            got.append(m)
            if got.count == 2 { break }
        }
        XCTAssertEqual(got.map(\.kind), [.published, .notification])
        XCTAssertEqual(got[0].event, "e")
        XCTAssertEqual(got[1].title, "T")

        var evs: [BeezyncSocketEvent] = []
        for await e in events {
            evs.append(e)
            if evs.count == 2 { break }
        }
        XCTAssertEqual(evs, [.connected(socketId: "s1"), .subscribed(channel: "a")])
        await client.disconnect()
    }

    func testConnectUsesConfiguredUrl() async throws {
        let box = SocketBox()
        let client = make(box: box)
        await client.connect()
        await waitUntil { box.count >= 1 }
        XCTAssertEqual(box.urls.first?.absoluteString, "ws://localhost:1/v1/ws?app_id=app&key=pk")
        await client.disconnect()
    }
}
