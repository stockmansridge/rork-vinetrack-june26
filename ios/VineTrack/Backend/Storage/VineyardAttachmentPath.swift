import Foundation

/// Storage mutations are admitted using their canonical owner, never selection.
nonisolated enum VineyardAttachmentPath {
    static func vineyard(_ path: String) throws -> UUID {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains("\\"), !path.contains("%"), !path.contains("?"), !path.contains("#"),
              let first = parts.first, let owner = UUID(uuidString: String(first)),
              String(first) == owner.uuidString.lowercased() else {
            throw VineyardWriteAuthority.Restricted(reason: "WRITE_SCOPE_UNRESOLVED")
        }
        return owner
    }
}
