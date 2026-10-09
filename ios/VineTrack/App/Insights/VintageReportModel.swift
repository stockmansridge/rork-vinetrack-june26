import Foundation
import Supabase
import Observation

/// Account/vineyard/vintage scoped report cache and exact-operation recovery. No generation on load.
@MainActor @Observable final class VintageReportModel {
    private(set) var cache = VintageReportCache()
    private(set) var isBusy: Bool = false
    var message: String?
    private var account: UUID?
    private var vineyard: UUID?
    private var vintage: Int = 0
    private var cacheURL: URL?
    private var generation: Int = 0
    private(set) var cacheUnreadable: Bool = false
    private var checkAccess: () -> Bool = { false }
    private var selectedThrough: String?
    var current: VintageReportRevision? { cache.revisions.first { $0.id == cache.currentID } }
    private var client: SupabaseClient { SupabaseClientProvider.shared.client }
    private var isScoped: Bool { checkAccess() && client.auth.currentUser?.id == account && account != nil && vineyard != nil }

    func configure(vineyard: UUID, vintage: Int, isCurrentScope: @escaping () -> Bool) async {
        generation += 1
        self.selectedThrough = nil
        self.cacheURL = nil
        self.checkAccess = isCurrentScope
        self.account = client.auth.currentUser?.id
        self.vineyard = vineyard; self.vintage = vintage; cache = VintageReportCache(); message = nil; isBusy = false; cacheUnreadable = false
        guard let account else { return }
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = root.appendingPathComponent("VintageReports/\(account.uuidString)/\(vineyard.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            cacheURL = folder.appendingPathComponent("\(vintage).json")
            if let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) {
                cache = try JSONDecoder().decode(VintageReportCache.self, from: Data(contentsOf: cacheURL))
            }
            await refresh()
        } catch { cacheUnreadable = true; message = "Saved cache is unreadable and has been preserved. Refresh to recover server requests before any new generation." }
    }
    private func persist(_ proposed: VintageReportCache? = nil) throws {
        guard isScoped, let cacheURL else { throw BackendRepositoryError.missingAuthenticatedUser }
        try JSONEncoder().encode(proposed ?? cache).write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func params(_ command: String, operation: UUID? = nil, expected: UUID? = nil, through: String? = nil, narrative: String? = nil, offset: Int = 0, beforeRevision: Int? = nil) throws -> [String: SprayReportPayloadV1.JSONValue] {
        guard isScoped, let vineyard, let account else { throw BackendRepositoryError.missingAuthenticatedUser }
        return ["p_author_id": .string(account.uuidString), "p_command": .string(command), "p_vineyard_id": .string(vineyard.uuidString), "p_vintage": .number(Double(vintage)),
                "p_operation_id": operation.map { .string($0.uuidString) } ?? .null,
                "p_expected_revision_id": expected.map { .string($0.uuidString) } ?? .null,
                "p_report_through": through.map { .string($0) } ?? .null,
                "p_content": narrative.map { .object(["narrative": .string($0)]) } ?? .null,
                "p_offset": .number(Double(offset)), "p_before_revision": beforeRevision.map { .number(Double($0)) } ?? .null]
    }
    func refresh() async {
        guard !isBusy, isScoped else { return }
        let scope = generation; isBusy = true
        defer { if scope == generation { isBusy = false } }
        do {
            var rows: [VintageReportRevision] = []; var offset: Int = 0
            var pointer: UUID?
            var beforeRevision: Int?
            repeat {
                let result: VintageReportRead = try await client.rpc("vintage_report_command", params: params("read", beforeRevision: beforeRevision)).execute().value
                guard scope == generation, isScoped else { return }
                if offset == 0 {
                    pointer = result.report?.currentRevisionID
                    if cache.pending == nil, let request = result.requests.first, let input = request.input {
                        cache.pending = VintageReportCommand(action: input.action, operation: request.operationID, expected: input.expected, through: input.through, narrative: input.content?.narrative)
                        cache.request = request
                    }
                }
                rows += result.revisions; offset += result.revisions.count
                beforeRevision = result.revisions.last?.revision
                if result.revisions.count < 20 { break }
            } while true
            cache.revisions = rows; cache.currentID = pointer
            let coverage: VintageReportCoverage = try await client.rpc("vintage_report_command", params: params("coverage", through: selectedThrough)).execute().value
            guard scope == generation, isScoped else { return }
            cache.coverage = coverage
            if cacheUnreadable, let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) {
                try FileManager.default.copyItem(at: cacheURL, to: cacheURL.appendingPathExtension("unreadable-\(UUID().uuidString)"))
            }
            try persist(); cacheUnreadable = false
            message = nil
        } catch { if scope == generation { message = "Server refresh unavailable. Downloaded revisions remain readable. Check connectivity and deployment, then retry." } }
    }
    func updateThrough(_ through: String) async {
        guard !isBusy, isScoped, !cacheUnreadable else { return }
        let scope = generation; isBusy = true
        defer { if scope == generation { isBusy = false } }
        do {
            let coverage: VintageReportCoverage = try await client.rpc("vintage_report_command", params: params("coverage", through: through)).execute().value
            guard scope == generation, isScoped else { return }
            selectedThrough = coverage.reportThrough
            cache.coverage = coverage; try persist()
        } catch { message = "Could not validate the reporting date against the vineyard season." }
    }
    func submit(action: String, through: String, narrative: String? = nil) async {
        guard !isBusy, isScoped, !cacheUnreadable, cache.pending == nil else { message = "Recover the existing request before starting another."; return }
        guard through.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { message = "Use YYYY-MM-DD for Report through."; return }
        selectedThrough = through
        let command = VintageReportCommand(action: action, operation: UUID(), expected: cache.currentID, through: through, narrative: narrative)
        do { cache.pending = command; cache.request = nil; try persist() }
        catch { cache.pending = nil; message = "Request could not be saved on this device. Nothing was sent."; return }
        await recover()
    }
    /// Reuses the exact authored operation and expected pointer after response loss or restart.
    func recover() async {
        guard !isBusy, isScoped, let command = cache.pending else { return }
        let scope = generation; isBusy = true
        defer { if scope == generation { isBusy = false } }
        do {
            var request: VintageReportRequest = try await client.rpc("vintage_report_command", params: params(command.action, operation: command.operation, expected: command.expected, through: command.through, narrative: command.narrative)).execute().value
            guard scope == generation, isScoped else { return }
            cache.request = request; try persist()
            if command.action != "edit", ["queued", "running", "failed"].contains(request.status) {
                request = try await client.functions.invoke("vintage-report", options: FunctionInvokeOptions(body: ["operation_id": command.operation.uuidString, "action": request.status == "queued" ? "execute" : "status"]))
                guard scope == generation, isScoped else { return }
                cache.request = request; try persist()
            }
            message = request.status == "unchanged" ? "No new information to add" : request.status == "failed" ? "Request failed: \(request.errorCode ?? "unknown outcome"). The previous report is unchanged. This operation will not repeat a paid call." : "Request \(request.status)."
            isBusy = false
            await refresh()
            guard scope == generation else { return }
            message = request.status == "unchanged" ? "No new information to add" : request.status == "failed" ? "Request failed: \(request.errorCode ?? "unknown outcome"). Previous report retained; no automatic paid retry." : "Request \(request.status)."
        } catch { if scope == generation { message = "Request outcome is uncertain. Recover this same request; do not start a replacement." } }
    }
    func acknowledgeResult() {
        guard !isBusy, let status = cache.request?.status, ["succeeded", "failed", "unchanged"].contains(status) else { return }
        do {
            var proposed = cache; proposed.pending = nil; proposed.request = nil
            try persist(proposed); cache = proposed
        }
        catch { message = "Could not acknowledge the saved result. Retry." }
    }
    /// A server-side cancellation fence safely resolves definitive rejections and queued requests.
    func abandonPending() async {
        guard !isBusy, isScoped, let command = cache.pending, let vineyard, let account else { return }
        let scope = generation; isBusy = true
        defer { if scope == generation { isBusy = false } }
        do {
            let input: SprayReportPayloadV1.JSONValue = .object([
                "action": .string(command.action), "through": .string(command.through),
                "expected": command.expected.map { .string($0.uuidString.lowercased()) } ?? .null,
                "content": command.narrative.map { .object(["narrative": .string($0)]) } ?? .null
            ])
            let request: VintageReportRequest = try await client.rpc("vintage_report_abandon", params: [
                "p_author_id": SprayReportPayloadV1.JSONValue.string(account.uuidString),
                "p_vineyard_id": .string(vineyard.uuidString),
                "p_vintage": .number(Double(vintage)), "p_operation_id": .string(command.operation.uuidString), "p_input": input
            ]).execute().value
            guard scope == generation, isScoped else { return }
            var proposed = cache; proposed.request = request; try persist(proposed); cache = proposed
            message = request.status == "running" ? "Already running. Recover its status; no replacement paid call is permitted." : "Cancellation receipt saved. Acknowledge the result to start a corrected request."
        } catch { if scope == generation { message = "Cancellation outcome is uncertain. Keep and recover this request." } }
    }

    func activate(_ revision: VintageReportRevision) async {
        guard !isBusy, isScoped else { return }
        let scope = generation; isBusy = true
        defer { if scope == generation { isBusy = false } }
        do {
            let _: VintageReportRevision = try await client.rpc("vintage_report_command", params: params("activate", operation: revision.operationID, expected: cache.pending?.expected ?? cache.currentID)).execute().value
            guard scope == generation, isScoped else { return }
            cache.currentID = revision.id; try persist(); message = "Revision made current."
        } catch { message = "Could not make this revision current. Another editor may have changed the report; refresh and review." }
    }
}
