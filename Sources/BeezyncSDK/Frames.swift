import Foundation

public struct BeezyncMessage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case published
        case notification
    }

    public let kind: Kind
    public let id: String?
    public let event: String?
    public let channel: String?
    public let title: String?
    public let body: String?
    public let data: JSONValue?
    public let timestamp: Double?
}

public enum BeezyncSocketEvent: Equatable, Sendable {
    case connected(socketId: String)
    case subscribed(channel: String)
    case subscriptionError(channel: String, error: String)
    case disconnected(closeCode: Int?)
}

enum ServerFrame: Equatable {
    case connectionEstablished(socketId: String)
    case subscriptionSucceeded(channel: String)
    case subscriptionError(channel: String, error: String)
    case pong
    case message(BeezyncMessage)
}

enum ClientFrame: Equatable {
    case subscribe(channel: String, auth: String?, token: String?)
    case unsubscribe(channel: String)
    case ping
}

enum FrameCodec {
    static func encode(_ frame: ClientFrame) -> String {
        var obj: [String: String]
        switch frame {
        case .subscribe(let channel, let auth, let token):
            obj = ["action": "subscribe", "channel": channel]
            if let auth, !auth.isEmpty { obj["auth"] = auth }
            if let token, !token.isEmpty { obj["token"] = token }
        case .unsubscribe(let channel):
            obj = ["action": "unsubscribe", "channel": channel]
        case .ping:
            obj = ["action": "ping"]
        }
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) -> ServerFrame? {
        guard let raw = text.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: raw),
              case .object(let o) = json else { return nil }

        if let event = o["event"]?.stringValue {
            switch event {
            case "connection_established":
                let data = payloadObject(o["data"])
                guard let id = data["socket_id"]?.stringValue else { return nil }
                return .connectionEstablished(socketId: id)
            case "subscription_succeeded":
                return .subscriptionSucceeded(channel: o["channel"]?.stringValue ?? "")
            case "subscription_error":
                return .subscriptionError(channel: o["channel"]?.stringValue ?? "", error: o["error"]?.stringValue ?? "")
            case "pong":
                return .pong
            default:
                return .message(BeezyncMessage(
                    kind: .published,
                    id: o["id"]?.stringValue,
                    event: event,
                    channel: o["channel"]?.stringValue,
                    title: nil,
                    body: nil,
                    data: o["data"],
                    timestamp: number(o["ts"])
                ))
            }
        }

        if o["title"] != nil || o["body"] != nil {
            return .message(BeezyncMessage(
                kind: .notification,
                id: o["id"]?.stringValue,
                event: nil,
                channel: o["channel"]?.stringValue,
                title: o["title"]?.stringValue,
                body: o["body"]?.stringValue,
                data: o["data"],
                timestamp: nil
            ))
        }
        return nil
    }

    private static func payloadObject(_ v: JSONValue?) -> [String: JSONValue] {
        switch v {
        case .object(let o): return o
        case .string(let s):
            if let d = s.data(using: .utf8), let parsed = try? JSONDecoder().decode(JSONValue.self, from: d),
               case .object(let o) = parsed { return o }
            return [:]
        default: return [:]
        }
    }

    private static func number(_ v: JSONValue?) -> Double? {
        if case .number(let n) = v { return n }
        return nil
    }
}
