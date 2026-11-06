import Foundation

public struct BeezyncConfiguration: Sendable, Equatable {
    public let appId: String
    public let publicKey: String
    public let baseUrl: URL

    public init(appId: String, publicKey: String, baseUrl: URL) {
        self.appId = appId
        self.publicKey = publicKey
        self.baseUrl = baseUrl
    }

    public init?(appId: String, publicKey: String, baseUrl: String) {
        guard let url = URL(string: baseUrl), url.host != nil else { return nil }
        self.init(appId: appId, publicKey: publicKey, baseUrl: url)
    }

    func endpoint(_ path: String) -> URL {
        var s = baseUrl.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + path)!
    }

    var webSocketUrl: URL {
        var c = URLComponents(url: endpoint("/v1/ws"), resolvingAgainstBaseURL: false)!
        c.scheme = (c.scheme == "https" || c.scheme == "wss") ? "wss" : "ws"
        c.queryItems = [URLQueryItem(name: "app_id", value: appId), URLQueryItem(name: "key", value: publicKey)]
        return c.url!
    }
}

public enum BeezyncError: Error, Equatable {
    case http(status: Int, code: String?, message: String?)
    case invalidResponse
    case network(String)
    case notRegistered
}
