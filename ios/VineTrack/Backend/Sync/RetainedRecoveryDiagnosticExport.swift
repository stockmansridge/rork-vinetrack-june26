import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// A forensic copy, not a backup restore format. No repositories or journal
/// constructors are called: some of those normalize data or create directories.
nonisolated enum RetainedRecoveryDiagnosticExport {
    struct FileEvidence: Codable, Sendable {
        let path: String
        let status: String
        let capturedAt: Date
        let bytes: Data?
        let sha256: String?
        let errorCode: Int?
    }
    struct Bundle: Codable, Sendable {
        let formatVersion: Int
        let startedAt: Date
        let finishedAt: Date
        let appVersion: String
        let appBuild: String
        let selectedOwnerId: String
        let selectedVineyardId: String
        let limitations: [String]
        let diagnosticsText: String
        let files: [FileEvidence]
    }

    // Explicit operational allowlist. Never export Keychain, preferences,
    // Supabase session storage, HTTP caches or the entire app container.
    static let keys = [
        "vinetrack_trips", "vinetrack_spray_records", "vinetrack_saved_chemicals",
        "vinetrack_spray_tank_actuals_v1", "vinetrack_start_tank_commit_v1",
        "vinetrack_legacy_spray_save_attempts_v1", "vinetrack_trip_sync_metadata", "vinetrack_trip_deletion_journal_v1",
        "vinetrack_spray_record_sync_metadata", "vinetrack_growth_stage_records",
        "vinetrack_growth_stage_record_sync_metadata", "vinetrack_growth_mirror_identity_evidence_v1",
        "vinetrack_pending_growth_photos_v1", "vinetrack_linked_pin_growth_deletions_v1",
        "vinetrack_pin_sync_metadata", "vinetrack_pending_pin_photos_v2",
        "vinetrack_pending_pin_location_confirmations_v1", "vinetrack_pending_pin_owners_v1",
        "vinetrack_paddock_sync_metadata", "vinetrack_button_config_sync_metadata",
        "vinetrack_saved_chemical_sync_metadata", "vinetrack_saved_spray_preset_sync_metadata",
        "vinetrack_saved_input_sync_metadata", "vinetrack_trip_cost_allocation_sync_metadata",
        "vinetrack_work_task_sync_metadata", "vinetrack_work_task_labour_line_sync_metadata",
        "vinetrack_work_task_machine_line_sync_metadata", "vinetrack_work_task_paddock_sync_metadata",
        "vinetrack_work_task_piece_rate_row_sync_metadata", "vinetrack_maintenance_log_sync_metadata",
        "vinetrack_yield_session_sync_metadata", "vinetrack_damage_record_sync_metadata",
        "vinetrack_historical_yield_sync_metadata", "vinetrack_fertiliser_record_sync_metadata",
        "vinetrack_picking_record_sync_metadata", "vinetrack_pruning_yield_settings_sync_metadata",
        "vinetrack_pruning_season_sync_metadata", "vinetrack_pruning_entry_sync_metadata",
        "vinetrack_pruning_edit_sync_metadata", "vinetrack_pruning_activity_sync_metadata",
        "vinetrack_pruning_activity_edit_sync_metadata", "vinetrack_pruning_activity_labour_sync_metadata",
        "vinetrack_growth_stage_image_sync_metadata", "vinetrack_growth_stage_image_pending",
        "vinetrack_spray_equipment_sync_metadata", "vinetrack_tractor_sync_metadata",
        "vinetrack_vineyard_machine_sync_metadata", "vinetrack_fuel_purchase_sync_metadata",
        "vinetrack_tractor_fuel_log_sync_metadata", "vinetrack_operator_category_sync_metadata",
        "vinetrack_work_task_type_sync_metadata", "vinetrack_equipment_item_sync_metadata",
        "vinetrack_vineyard_material_sync_metadata", "vinetrack_work_task_material_sync_metadata",
        "vinetrack_spray_target_library_outbox", "vinetrack_custom_pin_outbox", "vinetrack_manual_issue_outbox"
    ]
    static let journalDirectories = ["TripOccurrenceJournals", "SprayPlanningAttempts-v1", "RecoveryDecodeDiagnostics-v1"]

    static func capture(documents: URL, applicationSupport: URL, ownerId: String,
                        vineyardId: String, version: String, build: String, diagnostics: String) throws -> Data {
        let startedAt = Date()
        var files: [FileEvidence] = []
        let manager = FileManager.default
        let root = documents.appendingPathComponent("VineTrackData", isDirectory: true)
        if manager.fileExists(atPath: root.path), try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw CocoaError(.fileReadNoPermission)
        }
        func captureFile(_ url: URL, path: String) -> FileEvidence {
            let at = Date()
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    return FileEvidence(path: path, status: "not_regular_file", capturedAt: at, bytes: nil, sha256: nil, errorCode: nil)
                }
                let bytes = try Data(contentsOf: url)
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                // Detect a concurrent replacement; retain first bytes, never
                // lock, pause sync, retry a save, or assert cross-file atomicity.
                let verification = try? Data(contentsOf: url)
                let status = verification == nil ? "verification_read_error" : (verification == bytes ? "copied" : "changed_during_capture")
                return FileEvidence(path: path, status: status, capturedAt: at, bytes: bytes, sha256: hash, errorCode: nil)
            } catch {
                let e = error as NSError
                let missing = e.domain == NSCocoaErrorDomain && (e.code == NSFileReadNoSuchFileError || e.code == NSFileNoSuchFileError)
                return FileEvidence(path: path, status: missing ? "missing" : "read_error", capturedAt: at, bytes: nil, sha256: nil, errorCode: e.code)
            }
        }
        for key in keys {
            files.append(captureFile(root.appendingPathComponent(key + ".json"), path: "Documents/VineTrackData/\(key).json"))
        }
        for name in journalDirectories {
            let directory = applicationSupport.appendingPathComponent(name, isDirectory: true)
            let prefix = "Application Support/\(name)"
            guard manager.fileExists(atPath: directory.path) else {
                files.append(FileEvidence(path: prefix, status: "missing", capturedAt: Date(), bytes: nil, sha256: nil, errorCode: nil))
                continue
            }
            let directoryValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard directoryValues.isSymbolicLink != true else {
                files.append(FileEvidence(path: prefix, status: "not_regular_directory", capturedAt: Date(), bytes: nil, sha256: nil, errorCode: nil))
                continue
            }
            var enumerationErrors: [FileEvidence] = []
            let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [], errorHandler: { url, error in
                enumerationErrors.append(FileEvidence(path: prefix + "/" + url.lastPathComponent, status: "enumeration_error", capturedAt: Date(), bytes: nil, sha256: nil, errorCode: (error as NSError).code))
                return true
            })
            guard let enumerator else { throw CocoaError(.fileReadUnknown) }
            var found = false
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    files.append(FileEvidence(path: prefix + "/" + url.lastPathComponent, status: "symlink_excluded", capturedAt: Date(), bytes: nil, sha256: nil, errorCode: nil))
                    continue
                }
                if values.isDirectory == true { continue }
                // Journal roots contain operational evidence only. Retain all
                // regular files, including malformed JSON and interrupted writes.
                let baseComponents = directory.resolvingSymlinksInPath().pathComponents
                let fileComponents = url.resolvingSymlinksInPath().pathComponents
                guard fileComponents.starts(with: baseComponents) else { throw CocoaError(.fileReadNoPermission) }
                let relative = fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
                files.append(captureFile(url, path: prefix + "/" + relative)); found = true
            }
            files.append(contentsOf: enumerationErrors)
            if !found && enumerationErrors.isEmpty {
                files.append(FileEvidence(path: prefix, status: "empty_directory", capturedAt: Date(), bytes: nil, sha256: nil, errorCode: nil))
            }
        }
        let bundle = Bundle(formatVersion: 1, startedAt: startedAt, finishedAt: Date(), appVersion: version,
            appBuild: build, selectedOwnerId: ownerId, selectedVineyardId: vineyardId, limitations: [
                "Sensitive: raw operational records can include other accounts/vineyards retained on this device, locations, operator details, chemical history and embedded pending photographs. Share privately only.",
                "Sequential read-only capture, not an atomic cross-file snapshot. Original bytes are base64 with SHA256; no decode/re-encode or repair is performed.",
                "No network requests. Only previously retained server receipt evidence is included. Missing files are not proof of no server record or no pending work.",
                "Exact decode evidence is available only for instrumented failures observed after this feature was installed; earlier error paths/bodies cannot be reconstructed.",
                "No auth stores, Keychain, preference domains, separate media files or HTTP caches. Embedded pending photographs in allowlisted archives ARE included. Queue metadata is not a complete backup of every queued entity payload."
            ], diagnosticsText: diagnostics, files: files.sorted { $0.path < $1.path })
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }
}

struct RetainedRecoveryEvidenceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
