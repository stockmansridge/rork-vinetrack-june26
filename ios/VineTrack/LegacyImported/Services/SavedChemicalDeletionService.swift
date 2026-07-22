import Foundation

/// Result of attempting to archive or hard-delete a saved chemical via the
/// Supabase RPCs. The backend is the final authority — `chemicalInUse` is
/// returned when Supabase refuses a permanent delete because the chemical is
/// referenced by an operational/historical record.
enum SavedChemicalDeletionOutcome: Sendable {
    case archived
    case hardDeleted
    case chemicalInUse(message: String)
    case notFound
}

enum SavedChemicalDeletionError: LocalizedError {
    case archiveFailed
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .archiveFailed: return "Archive failed. Please try again."
        case .deleteFailed: return "Delete failed. Please try again."
        }
    }
}

/// Thin wrapper around `SavedChemicalSyncRepositoryProtocol` that maps the
/// raw RPC payloads into a UI-friendly outcome and never throws on the
/// expected `chemical_in_use` branch.
struct SavedChemicalDeletionService: Sendable {
    private let repository: any SavedChemicalSyncRepositoryProtocol

    init(repository: (any SavedChemicalSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseSavedChemicalSyncRepository()
    }

    func archive(id: UUID) async throws -> SavedChemicalDeletionOutcome {
        do {
            let result = try await repository.softDeleteRPC(id: id)
            if result.ok {
                return .archived
            }
            if result.reason == "not_found" {
                return .notFound
            }
            throw SavedChemicalDeletionError.archiveFailed
        } catch let error as SavedChemicalDeletionError {
            throw error
        } catch {
            #if DEBUG
            print("[SavedChemicalDeletion] archive failed: \(error.localizedDescription)")
            #endif
            throw SavedChemicalDeletionError.archiveFailed
        }
    }

    func hardDelete(id: UUID) async throws -> SavedChemicalDeletionOutcome {
        do {
            let result = try await repository.hardDeleteUnused(id: id)
            if result.ok {
                return .hardDeleted
            }
            if result.reason == "chemical_in_use" {
                let message = result.message ?? "This chemical has been used and cannot be permanently deleted. You can archive it instead."
                return .chemicalInUse(message: message)
            }
            if result.reason == "not_found" {
                return .notFound
            }
            throw SavedChemicalDeletionError.deleteFailed
        } catch let error as SavedChemicalDeletionError {
            throw error
        } catch {
            #if DEBUG
            print("[SavedChemicalDeletion] hard delete failed: \(error.localizedDescription)")
            #endif
            throw SavedChemicalDeletionError.deleteFailed
        }
    }
}
