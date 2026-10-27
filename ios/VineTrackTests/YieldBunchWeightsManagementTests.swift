import Foundation
import Testing
import PostgREST
@testable import VineTrack

@MainActor struct YieldBunchWeightsManagementTests {
    private let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let block = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let owner = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private func row(block: UUID? = nil, grams: Double = 120, key: String = "shiraz", vineyard: UUID? = nil) -> YieldBunchWeightRow {
        .init(id: UUID(), vineyardId: vineyard ?? self.vineyard, paddockId: block, varietyKey: key, varietyName: "Shiraz", grams: grams, updatedAt: nil)
    }
    @MainActor private final class Transport: YieldBunchWeightsTransport {
        var pages: [YieldBunchWeightsRepository.Page] = []
        var offsets: [Int] = []
        var owners: [VineyardMutationAdmission.Ownership] = []
        var writes: [YieldBunchWeightsRepository.SaveArgs] = []
        var deletes: [UUID] = []
        var beforePage: (() -> Void)?
        var beforeOwner: (() -> Void)?
        var writeError: Error?
        func page(vineyard: UUID, offset: Int) async throws -> YieldBunchWeightsRepository.Page {
            offsets.append(offset); beforePage?()
            guard !pages.isEmpty else { throw URLError(.notConnectedToInternet) }
            return pages.removeFirst()
        }
        func save(_ args: YieldBunchWeightsRepository.SaveArgs) async throws {
            writes.append(args)
            if let writeError { throw writeError }
        }
        func ownership(id: UUID) async throws -> [VineyardMutationAdmission.Ownership] { beforeOwner?(); return owners }
        func remove(id: UUID) async throws { deletes.append(id); if let writeError { throw writeError } }
    }
    @Test func overrideThenMasterThenUnconfiguredNeverHistoricalFallback() {
        let master = row(grams: 120), override = row(block: block, grams: 180)
        #expect(YieldBunchWeightRow.resolved([master, override], vineyard: vineyard, block: block, key: "shiraz").recordId == override.id)
        #expect(YieldBunchWeightRow.resolved([master], vineyard: vineyard, block: block, key: "shiraz").kg == 0.12)
        #expect(YieldBunchWeightRow.resolved([], vineyard: vineyard, block: block, key: "shiraz").kg == nil)
        #expect(YieldBunchWeightRow.resolved([override], vineyard: vineyard, block: UUID(), key: "shiraz").source == "not_configured")
        #expect(YieldBunchWeightRow.resolved([row(vineyard: UUID()), row(key: "merlot")], vineyard: vineyard, block: block, key: "shiraz").kg == nil)
    }
    @Test(arguments: [0.0, -1.0, 5000.1, Double.infinity, Double.nan])
    func rejectsInvalidGrams(grams: Double) { #expect(!row(grams: grams).isValid) }
    @Test func roleContractIncludesSupervisorButNotOperatorOrUnknown() {
        let access = BackendAccessControl()
        for role in BackendRole.allCases {
            access.currentRole = role
            #expect(access.canManageBunchWeights == (role != .operator))
        }
        access.currentRole = nil
        #expect(!access.canManageBunchWeights)
    }
    @Test func masterRequestEncodesNullBlockAndExactGrams() throws {
        let data = try JSONEncoder().encode(YieldBunchWeightsRepository.SaveArgs(p_vineyard_id: vineyard, p_paddock_id: nil, p_variety_key: "shiraz", p_variety_name: "Renamed Shiraz", p_bunch_weight_grams: 123.456))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["p_paddock_id"] is NSNull)
        #expect(body["p_bunch_weight_grams"] as? Double == 123.456)
        #expect(body["p_variety_key"] as? String == "shiraz")
    }
    @Test func fetchRequiresCompleteCountedPagesAndRetainsLastConfirmedOnFailure() async throws {
        let name = "weights-management-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = VineyardWriteAuthority(defaults: defaults); gate.bind(userId: owner)
        let transport = Transport(), first = row(), second = row(block: block)
        let repo = YieldBunchWeightsRepository(authority: gate, defaults: defaults, transport: transport, currentUserId: { owner })
        transport.pages = [.init(rows: [first], count: 2), .init(rows: [second], count: 2)]
        let rows = try await repo.fetch(vineyard: vineyard)
        #expect(rows.count == 2 && transport.offsets == [0, 1])
        transport.pages = [.init(rows: [first], count: 2)]
        do { _ = try await repo.fetch(vineyard: vineyard); Issue.record("Partial list accepted") } catch { }
        #expect(repo.cached(vineyard: vineyard) == rows)
        transport.pages = [.init(rows: [], count: nil)]
        do { _ = try await repo.fetch(vineyard: vineyard); Issue.record("Uncounted list accepted") } catch { }
        #expect(repo.cached(vineyard: vineyard) == rows)
    }
    @Test func changedCountDuplicatesAndCrossVineyardRowsNeverConfirmAbsence() async throws {
        let name = "weights-management-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = VineyardWriteAuthority(defaults: defaults); gate.bind(userId: owner)
        let transport = Transport(), first = row()
        let repo = YieldBunchWeightsRepository(authority: gate, defaults: defaults, transport: transport, currentUserId: { owner })
        let scenarios: [[YieldBunchWeightsRepository.Page]] = [
            [.init(rows: [first], count: 2), .init(rows: [first], count: 2)],
            [.init(rows: [first], count: 2), .init(rows: [], count: 0)],
            [.init(rows: [row(vineyard: UUID())], count: 1)]
        ]
        for pages in scenarios {
            transport.pages = pages
            do { _ = try await repo.fetch(vineyard: vineyard); Issue.record("Invalid complete list accepted") } catch { }
            #expect(repo.cached(vineyard: vineyard) == nil)
        }
    }
    @Test func heldWritesAndMismatchedDeleteOwnershipNeverReachMutationTransport() async throws {
        let name = "weights-management-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = VineyardWriteAuthority(defaults: defaults); gate.bind(userId: owner)
        let transport = Transport(), target = row(block: block)
        let repo = YieldBunchWeightsRepository(authority: gate, defaults: defaults, transport: transport, currentUserId: { owner })
        transport.owners = [.init(id: target.id, vineyardId: UUID())]
        do { try await repo.remove(target); Issue.record("Mismatched delete sent") } catch { }
        gate.hold(vineyardId: vineyard.uuidString, reason: "VT_READ_ONLY")
        do { try await repo.save(vineyard: vineyard, block: nil, key: "shiraz", name: "Shiraz", grams: 120); Issue.record("Held write sent") } catch { }
        #expect(transport.writes.isEmpty && transport.deletes.isEmpty)
    }
    @Test func sameAccountNewIncarnationCannotPublishReadOrSendDelete() async throws {
        let name = "weights-management-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = VineyardWriteAuthority(defaults: defaults); gate.bind(userId: owner)
        let transport = Transport(), target = row()
        let repo = YieldBunchWeightsRepository(authority: gate, defaults: defaults, transport: transport, currentUserId: { owner })
        transport.pages = [.init(rows: [target], count: 1)]
        transport.beforePage = { gate.bind(userId: nil); gate.bind(userId: owner) }
        do { _ = try await repo.fetch(vineyard: vineyard); Issue.record("Stale read published") } catch { }
        #expect(repo.cached(vineyard: vineyard) == nil)
        transport.owners = [.init(id: target.id, vineyardId: vineyard)]
        transport.beforeOwner = { gate.bind(userId: nil); gate.bind(userId: owner) }
        do { try await repo.remove(target); Issue.record("Stale delete sent") } catch { }
        #expect(transport.deletes.isEmpty)
    }
    @Test func permissionFailureNeverCreatesHoldAndUnknownSaveDoesNotCreateConfirmedCache() async throws {
        let name = "weights-management-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = VineyardWriteAuthority(defaults: defaults); gate.bind(userId: owner)
        let transport = Transport()
        let repo = YieldBunchWeightsRepository(authority: gate, defaults: defaults, transport: transport, currentUserId: { owner })
        for code in ["42501", "VT_READ_ONLY"] {
            transport.writeError = try JSONDecoder().decode(PostgrestError.self, from: Data("{\"code\":\"\(code)\",\"message\":\"Denied\"}".utf8))
            do { try await repo.save(vineyard: vineyard, block: nil, key: "shiraz", name: "Shiraz", grams: 120); Issue.record("Rejected save accepted") } catch { }
            #expect(gate.canWrite(vineyardId: vineyard.uuidString) == (code == "42501"))
            #expect(repo.cached(vineyard: vineyard) == nil)
        }
    }
    @Test func confirmedListInvalidatesOlderResolverAndRemovalRestoresMaster() async throws {
        let name = "weights-management-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let paddock = Paddock(id: block, vineyardId: vineyard, name: "Synthetic", varietyAllocations: [.init(varietyId: owner, percent: 100, name: "Renamed", varietyKey: "shiraz")])
        let master = row(grams: 120), override = row(block: block, grams: 180)
        var cache: YieldMasterWeightCache!
        cache = YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { 1 }, resolve: { _, _, key in
            cache.installConfirmedRows([master], vineyardId: vineyard, paddocks: [paddock])
            return .init(bunchWeightGrams: 180, source: "block_override", recordId: override.id, varietyKey: key)
        })
        cache.installConfirmedRows([master, override], vineyardId: vineyard, paddocks: [paddock])
        #expect(cache.weights(vineyardId: vineyard).values.first?.kg == 0.18)
        await cache.refresh(vineyardId: vineyard, paddocks: [paddock])
        #expect(cache.weights(vineyardId: vineyard).values.first?.kg == 0.12)
        cache.installConfirmedRows([], vineyardId: vineyard, paddocks: [paddock])
        #expect(cache.weights(vineyardId: vineyard).values.first?.source == "not_configured")
    }
}
