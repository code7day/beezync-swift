import Foundation

public enum BeezyncPush {
    public static let notificationIdKey = "bz_id"

    public static func notificationId(from userInfo: [AnyHashable: Any]) -> String? {
        if let id = clean(userInfo[notificationIdKey]) { return id }
        if let data = userInfo["data"] as? [AnyHashable: Any], let id = clean(data[notificationIdKey]) { return id }
        if let json = userInfo["data"] as? String,
           let raw = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let id = clean(obj[notificationIdKey]) { return id }
        return nil
    }

    private static func clean(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
