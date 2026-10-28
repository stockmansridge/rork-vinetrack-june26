import XCTest
@testable import VineTrack

final class WorkTaskAssignmentNamesTests: XCTestCase {
    @MainActor private func withCache(_ body: (WorkTaskAssignmentNames, UserDefaults) -> Void) {
        let suite = "assignment-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(WorkTaskAssignmentNames(defaults: defaults), defaults)
    }
    @MainActor func testAssignedMember() {
        withCache { cache, _ in
            let account = UUID(), vineyard = UUID()
            XCTAssertEqual(cache.resolve(account: account, vineyard: vineyard, member: account, external: nil, label: "  Alex Chen  "), "Alex Chen")
        }
    }
    @MainActor func testAnotherMemberProfilePrefersNonblankFullName() {
        withCache { cache, _ in
            let member = BackendVineyardMember(id: nil, vineyardId: UUID(), userId: UUID(), role: .operator, displayName: "Sam", fullName: " ")
            XCTAssertEqual(cache.resolve(account: UUID(), vineyard: member.vineyardId, member: member.userId, external: nil, label: WorkTaskAssignmentNames.memberName(member)), "Sam")
        }
    }
    @MainActor func testExternalResource() {
        withCache { cache, _ in XCTAssertEqual(cache.resolve(account: UUID(), vineyard: UUID(), member: nil, external: UUID(), label: "River Crew"), "River Crew") }
    }
    @MainActor func testUnassignedNeverUsesOldLabel() {
        withCache { cache, _ in XCTAssertEqual(cache.resolve(account: UUID(), vineyard: UUID(), member: nil, external: nil, label: "Old name"), "") }
    }
    @MainActor func testHistoricalDraftRejectsIdentifierFragments() {
        withCache { cache, _ in
            let a = UUID(), v = UUID(), m = UUID()
            for label in ["Vineyard member (12345678)", "User deadbeef", m.uuidString] {
                XCTAssertEqual(cache.resolve(account: a, vineyard: v, member: m, external: nil, label: label), "Assigned vineyard member")
            }
        }
    }
    @MainActor func testOfflineReopenUsesPersistedPresentation() {
        withCache { cache, defaults in
            let a = UUID(), v = UUID(), m = UUID()
            _ = cache.resolve(account: a, vineyard: v, member: m, external: nil, label: "Alex Chen")
            XCTAssertEqual(WorkTaskAssignmentNames(defaults: defaults).resolve(account: a, vineyard: v, member: m, external: nil), "Alex Chen")
        }
    }
    @MainActor func testVineyardAccountAndKindIsolation() {
        withCache { cache, _ in
            let a = UUID(), v = UUID(), m = UUID()
            _ = cache.resolve(account: a, vineyard: v, member: m, external: nil, label: "Alex Chen")
            XCTAssertEqual(cache.resolve(account: a, vineyard: UUID(), member: m, external: nil), "Assigned vineyard member")
            XCTAssertEqual(cache.resolve(account: UUID(), vineyard: v, member: m, external: nil), "Assigned vineyard member")
            XCTAssertEqual(cache.resolve(account: a, vineyard: v, member: nil, external: m), "Assigned external resource")
        }
    }
    @MainActor func testInactiveHistoricalAssigneeRetainsResolvedName() {
        withCache { cache, _ in
            let a = UUID(), v = UUID(), m = UUID()
            _ = cache.resolve(account: a, vineyard: v, member: m, external: nil, label: "Former operator")
            XCTAssertEqual(cache.resolve(account: a, vineyard: v, member: m, external: nil, label: ""), "Former operator")
        }
    }
}
