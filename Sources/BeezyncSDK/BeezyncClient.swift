import Foundation

public actor BeezyncClient {
    public enum NotificationEvent: String, Sendable {
        case received, clicked, dismissed
    }

    public let configuration: BeezyncConfiguration

    private let http: HTTPClient
    private let session: URLSession
    private let socketFactory: @Sendable (URL) -> SocketConnection
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let randomSource: @Sendable () -> Double
    private let pingInterval: TimeInterval

    private var backoff = Backoff()
    private var subscriptions: [String: (auth: String?, token: String?)] = [:]
    private var socket: SocketConnection?
    private var runTask: Task<Void, Never>?
    private var wantsConnection = false
    private var socketConnected = false
    private var currentSocketId: String?
    private var deviceToken: String?
    private var messageSinks: [UUID: AsyncStream<BeezyncMessage>.Continuation] = [:]
    private var eventSinks: [UUID: AsyncStream<BeezyncSocketEvent>.Continuation] = [:]

    public init(configuration: BeezyncConfiguration, session: URLSession = .shared) {
        self.init(
            configuration: configuration,
            session: session,
            socketFactory: { URLSessionSocket(url: $0, session: session) },
            sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
            random: { Double.random(in: 0..<1) },
            pingInterval: 25
        )
    }

    init(
        configuration: BeezyncConfiguration,
        session: URLSession,
        socketFactory: @escaping @Sendable (URL) -> SocketConnection,
        sleep: @escaping @Sendable (TimeInterval) async -> Void,
        random: @escaping @Sendable () -> Double,
        pingInterval: TimeInterval
    ) {
        self.configuration = configuration
        self.session = session
        self.http = HTTPClient(config: configuration, session: session)
        self.socketFactory = socketFactory
        self.sleeper = sleep
        self.randomSource = random
        self.pingInterval = pingInterval
    }

    // MARK: Devices

    public func registerDevice(
        token: String,
        externalUserId: String? = nil,
        platform: String = "ios",
        tags: [String: JSONValue]? = nil
    ) async throws {
        struct Body: Encodable {
            let token: String
            let platform: String
            let external_user_id: String?
        }
        try await http.send("POST", "/v1/api/register-device", body: Body(token: token, platform: platform, external_user_id: externalUserId))
        deviceToken = token
        if let tags, !tags.isEmpty {
            try await setTags(tags)
        }
    }

    public func unregisterDevice(token: String? = nil) async throws {
        struct Body: Encodable { let token: String }
        guard let t = token ?? deviceToken else { throw BeezyncError.notRegistered }
        try await http.send("POST", "/v1/api/unregister-device", body: Body(token: t))
        if t == deviceToken { deviceToken = nil }
    }

    public func setUser(_ externalUserId: String) async throws {
        struct Body: Encodable {
            let token: String
            let external_user_id: String
        }
        guard let t = deviceToken else { throw BeezyncError.notRegistered }
        try await http.send("PATCH", "/v1/api/devices", body: Body(token: t, external_user_id: externalUserId))
    }

    public func setTags(_ tags: [String: JSONValue]) async throws {
        struct Body: Encodable {
            let token: String
            let tags: [String: JSONValue]
        }
        guard let t = deviceToken else { throw BeezyncError.notRegistered }
        try await http.send("PATCH", "/v1/api/devices", body: Body(token: t, tags: tags))
    }

    // MARK: Notification events

    public func trackReceived(_ notificationId: String) async throws {
        try await track(notificationId, .received)
    }

    public func trackClicked(_ notificationId: String) async throws {
        try await track(notificationId, .clicked)
    }

    public func trackDismissed(_ notificationId: String) async throws {
        try await track(notificationId, .dismissed)
    }

    public func track(_ notificationId: String, _ event: NotificationEvent) async throws {
        struct Body: Encodable {
            let notification_id: String
            let event: String
            let token: String?
        }
        try await http.send("POST", "/v1/api/notification-events", body: Body(notification_id: notificationId, event: event.rawValue, token: deviceToken))
    }

    // MARK: Streams

    public func messages() -> AsyncStream<BeezyncMessage> {
        let id = UUID()
        return AsyncStream { continuation in
            messageSinks[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeMessageSink(id) }
            }
        }
    }

    public func events() -> AsyncStream<BeezyncSocketEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventSinks[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventSink(id) }
            }
        }
    }

    public func onMessage(_ handler: @escaping @Sendable (BeezyncMessage) -> Void) -> Task<Void, Never> {
        let stream = messages()
        return Task {
            for await m in stream { handler(m) }
        }
    }

    private func removeMessageSink(_ id: UUID) { messageSinks[id] = nil }
    private func removeEventSink(_ id: UUID) { eventSinks[id] = nil }

    // MARK: WebSocket

    public var isConnected: Bool { socketConnected }
    public var socketId: String? { currentSocketId }

    public func connect() {
        guard !wantsConnection else { return }
        wantsConnection = true
        backoff.reset()
        runTask = Task { await self.run() }
    }

    public func disconnect() {
        wantsConnection = false
        runTask?.cancel()
        runTask = nil
        socket?.close()
        socket = nil
        socketConnected = false
        currentSocketId = nil
    }

    public func subscribe(_ channel: String, auth: String? = nil, token: String? = nil) async {
        subscriptions[channel] = (auth, token)
        if socketConnected {
            await sendFrame(.subscribe(channel: channel, auth: auth, token: token))
        }
    }

    public func unsubscribe(_ channel: String) async {
        subscriptions[channel] = nil
        if socketConnected {
            await sendFrame(.unsubscribe(channel: channel))
        }
    }

    public var subscribedChannels: [String] { subscriptions.keys.sorted() }

    private func sendFrame(_ frame: ClientFrame) async {
        try? await socket?.send(FrameCodec.encode(frame))
    }

    private func run() async {
        while wantsConnection && !Task.isCancelled {
            let conn = socketFactory(configuration.webSocketUrl)
            socket = conn
            conn.open()
            var closeCode: Int?
            let pinger = startPinger(conn)
            do {
                try await readLoop(conn)
            } catch SocketError.closed(let code) {
                closeCode = code
            } catch {}
            pinger.cancel()
            conn.close()
            if socket === conn { socket = nil }
            socketConnected = false
            currentSocketId = nil
            guard wantsConnection && !Task.isCancelled else { break }
            emit(.disconnected(closeCode: closeCode))
            let delay: TimeInterval
            if closeCode == 4200 {
                backoff.reset()
                delay = 0
            } else {
                delay = backoff.next(random: randomSource())
            }
            if delay > 0 { await sleeper(delay) }
        }
    }

    private func startPinger(_ conn: SocketConnection) -> Task<Void, Never> {
        let interval = pingInterval
        let sleeper = self.sleeper
        return Task {
            while !Task.isCancelled {
                await sleeper(interval)
                if Task.isCancelled { break }
                try? await conn.send(FrameCodec.encode(.ping))
            }
        }
    }

    private func readLoop(_ conn: SocketConnection) async throws {
        while !Task.isCancelled {
            let text = try await conn.receive()
            guard let frame = FrameCodec.decode(text) else { continue }
            await handle(frame)
        }
    }

    private func handle(_ frame: ServerFrame) async {
        switch frame {
        case .connectionEstablished(let id):
            socketConnected = true
            currentSocketId = id
            backoff.reset()
            emit(.connected(socketId: id))
            for (channel, creds) in subscriptions.sorted(by: { $0.key < $1.key }) {
                await sendFrame(.subscribe(channel: channel, auth: creds.auth, token: creds.token))
            }
        case .subscriptionSucceeded(let channel):
            emit(.subscribed(channel: channel))
        case .subscriptionError(let channel, let error):
            emit(.subscriptionError(channel: channel, error: error))
        case .pong:
            break
        case .message(let m):
            for sink in messageSinks.values { sink.yield(m) }
        }
    }

    private func emit(_ event: BeezyncSocketEvent) {
        for sink in eventSinks.values { sink.yield(event) }
    }
}
