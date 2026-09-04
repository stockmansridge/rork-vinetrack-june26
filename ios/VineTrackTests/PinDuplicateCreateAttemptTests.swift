import XCTest
@testable import VineTrack

@MainActor
final class PinDuplicateCreateAttemptTests: XCTestCase {
    func testCreateAnywayCommitsExactlyOnce() {
        var creates = 0
        let attempt = PinDuplicateCreateAttempt { creates += 1 }
        XCTAssertTrue(attempt.createAnyway())
        XCTAssertFalse(attempt.createAnyway())
        XCTAssertEqual(creates, 1)
    }

    func testCancelCreatesNothingAndFutureAttemptRemainsEnabled() {
        var creates = 0
        let cancelled = PinDuplicateCreateAttempt { creates += 1 }
        XCTAssertTrue(cancelled.cancel())
        XCTAssertFalse(cancelled.createAnyway())
        XCTAssertEqual(creates, 0)

        let future = PinDuplicateCreateAttempt { creates += 1 }
        XCTAssertTrue(future.createAnyway())
        XCTAssertEqual(creates, 1)
    }
}
