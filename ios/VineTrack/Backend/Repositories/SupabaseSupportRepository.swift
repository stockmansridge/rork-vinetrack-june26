import Foundation
import Supabase

/// Backend pathway for the in-app support / feedback / feature-request form.
///
/// Flow (durable-first):
///   1. Upload any attachments to the private `support-attachments` bucket,
///      namespaced as `{user_id}/{request_id}/attachment-N.jpg`.
///   2. Insert a `support_requests` row (RLS: own user only). This is the
///      path that must never be lost — once it succeeds the request is stored
///      and visible in the admin portal.
///   3. Best-effort: invoke the `support-request` edge function to email the
///      support inbox and record `email_status` on the row.
///
/// A failure in step 3 does NOT fail the submission — the row is already
/// stored. The returned `emailStatus` lets the UI report delivery honestly.
nonisolated struct SupabaseSupportRepository: Sendable {
    static let attachmentsBucket = "support-attachments"
    static let edgeFunctionName = "support-request"

    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func submit(
        category: SupportRequestCategory,
        subject: String,
        message: String,
        submitterName: String?,
        submitterEmail: String?,
        vineyardId: UUID?,
        vineyardName: String?,
        attachments: [Data],
        diagnostics: SupportDiagnostics
    ) async throws -> SupportSubmissionResult {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }

        let session = try await provider.client.auth.session
        let userId = session.user.id
        let requestId = UUID()

        // 1. Upload attachments (own folder). A failed upload aborts before
        //    insert so the request is not stored referencing a missing file.
        var attachmentPaths: [String] = []
        for (index, raw) in attachments.enumerated() {
            let payload = PinPhotoStorage.compress(raw) ?? raw
            let path = "\(userId.uuidString.lowercased())/\(requestId.uuidString.lowercased())/attachment-\(index).jpg"
            _ = try await provider.client.storage
                .from(Self.attachmentsBucket)
                .upload(
                    path,
                    data: payload,
                    options: FileOptions(
                        cacheControl: "3600",
                        contentType: "image/jpeg",
                        upsert: true
                    )
                )
            attachmentPaths.append(path)
        }

        // 2. Insert the durable row.
        let insert = SupportRequestInsert(
            id: requestId.uuidString.lowercased(),
            userId: userId.uuidString.lowercased(),
            submitterName: submitterName?.nonEmpty,
            submitterEmail: submitterEmail?.nonEmpty,
            vineyardId: vineyardId?.uuidString.lowercased(),
            vineyardName: vineyardName?.nonEmpty,
            category: category.rawValue,
            subject: subject,
            message: message,
            attachmentPaths: attachmentPaths,
            attachmentCount: attachmentPaths.count,
            appPlatform: diagnostics.appPlatform,
            appVersion: diagnostics.appVersion,
            appBuild: diagnostics.appBuild,
            deviceModel: diagnostics.deviceModel,
            osVersion: diagnostics.osVersion
        )
        try await provider.client
            .from("support_requests")
            .insert(insert)
            .execute()

        // 3. Invoke production email delivery after the durable row is saved.
        // A delivery failure remains non-fatal because the request already exists.
        let emailOutcome = await notifyEmail(requestId: requestId, token: session.accessToken)

        return SupportSubmissionResult(
            requestSaved: true,
            staffEmailSent: emailOutcome.staffEmailSent,
            receiptEmailSent: emailOutcome.receiptEmailSent,
            attachmentCount: attachmentPaths.count
        )
    }

    /// Invokes the edge function and returns each accepted email outcome. Any
    /// failure here is non-fatal because the durable request row already exists.
    private func notifyEmail(requestId: UUID, token: String) async -> SupportEmailOutcome {
        let base = AppConfig.supabaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/functions/v1/\(Self.edgeFunctionName)") else {
            return .notSent
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: [
                "request_id": requestId.uuidString.lowercased(),
                "source_platform": "ios"
            ]
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .notSent }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (200..<300).contains(http.statusCode), body?["success"] as? Bool == true {
                let outcome = SupportEmailOutcome(
                    staffEmailSent: body?["staff_email_sent"] as? Bool ?? false,
                    receiptEmailSent: body?["receipt_email_sent"] as? Bool ?? false
                )
                print("[SupportRequest] id=\(requestId.uuidString.lowercased()) staff=\(outcome.staffEmailSent) receipt=\(outcome.receiptEmailSent)")
                return outcome
            }
            print("[SupportRequest] id=\(requestId.uuidString.lowercased()) email notify HTTP \(http.statusCode)")
            return .notSent
        } catch {
            print("[SupportRequest] id=\(requestId.uuidString.lowercased()) email notify error=\(error.localizedDescription)")
            return .notSent
        }
    }
}

nonisolated private struct SupportEmailOutcome: Sendable {
    let staffEmailSent: Bool
    let receiptEmailSent: Bool

    static let notSent = SupportEmailOutcome(staffEmailSent: false, receiptEmailSent: false)
}

nonisolated private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
