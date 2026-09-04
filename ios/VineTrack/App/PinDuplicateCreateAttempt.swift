import Foundation

/// One advisory warning decision. Create-anyway can commit once; cancel or
/// view-existing resolves the attempt without creating.
@MainActor
final class PinDuplicateCreateAttempt {
    private let create: () -> Void
    private(set) var isResolved: Bool = false

    init(create: @escaping () -> Void) {
        self.create = create
    }

    @discardableResult
    func createAnyway() -> Bool {
        guard !isResolved else { return false }
        isResolved = true
        create()
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        guard !isResolved else { return false }
        isResolved = true
        return true
    }
}
