import Foundation
import Testing
@testable import VineTrack

/// Local investigation only. No network, production accounts or changed expectations.
@MainActor
@Suite(.serialized)
struct PerformanceValidationTests {
    @Test func overlappingCatalogueReadsShareAndCompletedResultsAreNotCached() async throws {
        let flight = CatalogReadSingleFlight<Int>()
        let account = UUID()
        var requests = 0
        let request: @MainActor @Sendable () async throws -> Int = {
            requests += 1
            try await Task.sleep(for: .milliseconds(100))
            return 42
        }
        async let first = flight.read(account: account, request: request)
        async let second = flight.read(account: account, request: request)
        let values = try await [first, second]
        #expect(values == [42, 42])
        #expect(requests == 1)
        let fresh = try await flight.read(account: account) { 9 }
        #expect(fresh == 9)
    }

    @Test func catalogueFailureIsNotRetainedAndAccountsDoNotShare() async throws {
        let flight = CatalogReadSingleFlight<Int>()
        let account = UUID()
        do {
            _ = try await flight.read(account: account) { throw URLError(.timedOut) }
            Issue.record("Expected fixture transport failure")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        let next = try await flight.read(account: account) { 7 }
        #expect(next == 7)
        async let a = flight.read(account: account) {
            try await Task.sleep(for: .milliseconds(50))
            return 1
        }
        async let b = flight.read(account: UUID()) { 2 }
        let values = try await [a, b]
        #expect(values == [1, 2])
    }

    @Test func cancelledCatalogueWaiterDoesNotCancelOtherWaiter() async throws {
        let flight = CatalogReadSingleFlight<Int>()
        let account = UUID()
        let first = Task { @MainActor in
            try await flight.read(account: account) {
                try await Task.sleep(for: .milliseconds(100))
                return 42
            }
        }
        let second = Task { @MainActor in
            try await flight.read(account: account) {
                try await Task.sleep(for: .milliseconds(100))
                return 42
            }
        }
        first.cancel()
        let value = try await second.value
        #expect(value == 42)
        do {
            _ = try await first.value
            Issue.record("Cancelled waiter must not publish a value")
        } catch is CancellationError { }
    }

    @Test func rejectedPerformanceAccessCannotEnableOrExport() {
        let capture = PerformanceCapture()
        capture.authorize(false)
        capture.setEnabled(true)
        capture.mark("test fixed marker")
        #expect(!capture.isEnabled)
        #expect(capture.report() == nil)
        capture.revoke()
        #expect(capture.report() == nil)
    }
}
