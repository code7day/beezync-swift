import XCTest
@testable import BeezyncSDK

final class BackoffTests: XCTestCase {
    func testSequenceWithoutJitterRandom() {
        var b = Backoff()
        let seq = (0..<8).map { _ in b.next(random: 0) }
        XCTAssertEqual(seq, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testJitterStaysInRange() {
        for attempt in 0..<10 {
            let lo = Backoff.delay(attempt: attempt, base: 1, cap: 30, jitter: 0.25, random: 0)
            let hi = Backoff.delay(attempt: attempt, base: 1, cap: 30, jitter: 0.25, random: 1)
            XCTAssertGreaterThanOrEqual(lo, 1)
            XCTAssertLessThanOrEqual(hi, 30)
            XCTAssertLessThanOrEqual(lo, hi)
        }
        XCTAssertEqual(Backoff.delay(attempt: 2, base: 1, cap: 30, jitter: 0.25, random: 1), 5)
    }

    func testResetAndHugeAttempt() {
        var b = Backoff()
        _ = b.next(random: 0)
        _ = b.next(random: 0)
        b.reset()
        XCTAssertEqual(b.next(random: 0), 1)
        XCTAssertEqual(Backoff.delay(attempt: 10_000, base: 1, cap: 30, jitter: 0.25, random: 1), 30)
    }
}
