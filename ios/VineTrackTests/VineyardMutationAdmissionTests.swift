import Foundation
import Testing
import Supabase
@testable import VineTrack

@MainActor
struct VineyardMutationAdmissionTests {
    private func authority(owner: UUID) -> VineyardWriteAuthority {
        let gate = VineyardWriteAuthority(defaults: UserDefaults(suiteName: "mutation-admission-" + UUID().uuidString)!)
        gate.bind(userId: owner)
        return gate
    }

    @Test func restoredSDKSessionCannotBypassHoldBeforeLedgerAccountBinding() throws {
        let owner = UUID(), a = UUID()
        let gate = authority(owner: owner)
        gate.hold(vineyardId: a.uuidString, reason: "VT_READ_ONLY")
        gate.bind(userId: nil)
        #expect(throws: BackendRepositoryError.self) {
            try VineyardMutationAdmission(currentUserId: { owner }, authority: gate)
        }
        gate.bind(userId: owner)
        #expect(throws: VineyardWriteAuthority.Restricted.self) {
            try VineyardMutationAdmission(currentUserId: { owner }, authority: gate).requireWrite(vineyardId: a)
        }
    }

    @Test func onlyExplicitNewCreateScopeCanResolveAbsentRow() async throws {
        let owner = UUID(), id = UUID(), a = UUID()
        let gate = authority(owner: owner)
        let admission = try VineyardMutationAdmission(currentUserId: { owner }, authority: gate)
        let scope = try await admission.resolve(id: id, expectedVineyardId: a, allowMissingForCreate: true) { [] }
        #expect(scope == a)
        do {
            _ = try await admission.resolve(id: id, allowMissingForCreate: true) { [] }
            Issue.record("Missing create vineyard was guessed")
        } catch { #expect(error is VineyardWriteAuthority.Restricted) }
        gate.hold(vineyardId: a.uuidString, reason: "VT_READ_ONLY")
        do {
            _ = try await admission.resolve(id: id, expectedVineyardId: a, allowMissingForCreate: true) { [] }
            Issue.record("Held new create was admitted")
        } catch { #expect(error is VineyardWriteAuthority.Restricted) }
    }

    @Test func heldActualOwnerCannotBorrowWritableVineyard() async throws {
        let owner = UUID(), id = UUID(), a = UUID(), b = UUID()
        let gate = authority(owner: owner)
        gate.hold(vineyardId: a.uuidString, reason: "VT_READ_ONLY")
        let admission = try VineyardMutationAdmission(currentUserId: { owner }, authority: gate)
        var sends = 0
        do {
            let scope = try await admission.resolve(id: id) { [.init(id: id, vineyardId: a)] }
            try await admission.send(vineyardId: scope) { sends += 1 }
            Issue.record("Held owning vineyard was admitted")
        } catch { #expect(error is VineyardWriteAuthority.Restricted) }
        #expect(sends == 0 && gate.canWrite(vineyardId: b.uuidString))
    }

    @Test func absentDuplicateWrongIdAndWrongVineyardNeverResolve() async throws {
        let owner = UUID(), id = UUID(), a = UUID()
        let gate = authority(owner: owner)
        let admission = try VineyardMutationAdmission(currentUserId: { owner }, authority: gate)
        let invalid: [[VineyardMutationAdmission.Ownership]] = [
            [], [.init(id: id, vineyardId: a), .init(id: id, vineyardId: a)],
            [.init(id: UUID(), vineyardId: a)], [.init(id: id, vineyardId: UUID())]
        ]
        for rows in invalid {
            do {
                _ = try await admission.resolve(id: id, expectedVineyardId: a) { rows }
                Issue.record("Unresolved or mismatched identity was admitted")
            } catch { #expect(error is VineyardWriteAuthority.Restricted) }
        }
    }

    @Test func expiryDuringOwnershipReadStopsSend() async throws {
        let owner = UUID(), id = UUID(), a = UUID()
        let gate = authority(owner: owner)
        let admission = try VineyardMutationAdmission(currentUserId: { owner }, authority: gate)
        do {
            _ = try await admission.resolve(id: id) {
                await Task.yield()
                gate.hold(vineyardId: a.uuidString, reason: "VT_READ_ONLY")
                return [.init(id: id, vineyardId: a)]
            }
            Issue.record("Ownership read released an expired write")
        } catch { #expect(error is VineyardWriteAuthority.Restricted) }
    }

    @Test func accountSwitchDuringOwnershipReadStopsSend() async throws {
        let original = UUID(), other = UUID(), id = UUID(), a = UUID()
        var actor = original
        let gate = authority(owner: original)
        let admission = try VineyardMutationAdmission(currentUserId: { actor }, authority: gate)
        do {
            _ = try await admission.resolve(id: id) {
                await Task.yield()
                actor = other
                gate.bind(userId: other)
                return [.init(id: id, vineyardId: a)]
            }
            Issue.record("Stale account's ownership result was admitted")
        } catch { #expect(error is BackendRepositoryError) }
        #expect(gate.canWrite(vineyardId: a.uuidString))
    }

    @Test func staleStructuredRejectionDoesNotHoldNewAccount() async throws {
        let original = UUID(), other = UUID(), a = UUID()
        var actor = original
        let gate = authority(owner: original)
        let admission = try VineyardMutationAdmission(currentUserId: { actor }, authority: gate)
        let rejection = try JSONDecoder().decode(PostgrestError.self, from: Data(#"{"code":"VT_READ_ONLY","message":"Read only"}"#.utf8))
        do {
            try await admission.send(vineyardId: a) {
                actor = other
                gate.bind(userId: other)
                throw rejection
            }
            Issue.record("Expected rejection")
        } catch { #expect(error is BackendRepositoryError) }
        #expect(gate.canWrite(vineyardId: a.uuidString))
        gate.bind(userId: original)
        #expect(gate.canWrite(vineyardId: a.uuidString))
    }

    @Test func structuredRejectionHoldsButOrdinaryPermissionFailureDoesNot() async throws {
        let owner = UUID(), a = UUID(), b = UUID()
        let gate = authority(owner: owner)
        let admission = try VineyardMutationAdmission(currentUserId: { owner }, authority: gate)
        for (scope, code) in [(a, "VT_READ_ONLY"), (b, "42501")] {
            let rejection = try JSONDecoder().decode(PostgrestError.self, from: Data("{\"code\":\"\(code)\",\"message\":\"Denied\"}".utf8))
            do { try await admission.send(vineyardId: scope) { throw rejection } }
            catch {
                #expect((error is VineyardWriteAuthority.Restricted) == (code == "VT_READ_ONLY"))
            }
        }
        #expect(!gate.canWrite(vineyardId: a.uuidString))
        #expect(gate.canWrite(vineyardId: b.uuidString))
    }

    @Test func genuineReceiptSurvivesExpiryButNextSendIsHeld() async throws {
        let owner = UUID(), a = UUID(), receipt = UUID()
        let gate = authority(owner: owner)
        let admission = try VineyardMutationAdmission(currentUserId: { owner }, authority: gate)
        let actual = try await admission.send(vineyardId: a) {
            gate.hold(vineyardId: a.uuidString, reason: "VT_READ_ONLY")
            return receipt
        }
        #expect(actual == receipt)
        var sends = 0
        do {
            try await admission.send(vineyardId: a) { sends += 1 }
            Issue.record("Independent subsequent send was not held")
        } catch { #expect(error is VineyardWriteAuthority.Restricted) }
        #expect(sends == 0)
    }
}
