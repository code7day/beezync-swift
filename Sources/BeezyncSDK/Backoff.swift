import Foundation

public struct Backoff: Sendable {
    public let base: TimeInterval
    public let cap: TimeInterval
    public let jitter: Double
    public private(set) var attempt = 0

    public init(base: TimeInterval = 1, cap: TimeInterval = 30, jitter: Double = 0.25) {
        self.base = base
        self.cap = cap
        self.jitter = jitter
    }

    public static func delay(attempt: Int, base: TimeInterval, cap: TimeInterval, jitter: Double, random: Double) -> TimeInterval {
        let exp = min(max(attempt, 0), 30)
        let raw = min(cap, base * pow(2, Double(exp)))
        let r = min(max(random, 0), 1)
        return min(cap, raw * (1 + jitter * r))
    }

    public mutating func next(random: Double = Double.random(in: 0..<1)) -> TimeInterval {
        let d = Backoff.delay(attempt: attempt, base: base, cap: cap, jitter: jitter, random: random)
        attempt += 1
        return d
    }

    public mutating func reset() {
        attempt = 0
    }
}
