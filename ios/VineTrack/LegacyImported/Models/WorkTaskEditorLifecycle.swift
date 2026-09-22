import Foundation

/// Two-stage Work Task editor state. The locally persisted parent identity is
/// retained before any server refresh so child records can use the same UUID
/// online and offline.
nonisolated struct WorkTaskEditorLifecycle: Equatable, Sendable {
    private(set) var persistedTaskID: UUID?

    init(persistedTaskID: UUID? = nil) {
        self.persistedTaskID = persistedTaskID
    }

    var hasPersistedTask: Bool { persistedTaskID != nil }
    var saveTitle: String { hasPersistedTask ? "Save & Close" : "Save" }
    var childControlsEnabled: Bool { hasPersistedTask }

    /// First save retains the minted UUID and deliberately keeps the editor open.
    mutating func acceptFirstSave(taskID: UUID) {
        persistedTaskID = taskID
    }

    /// Only a save that began with an existing local parent closes the editor.
    func shouldCloseAfterAcceptedSave() -> Bool {
        hasPersistedTask
    }
}
