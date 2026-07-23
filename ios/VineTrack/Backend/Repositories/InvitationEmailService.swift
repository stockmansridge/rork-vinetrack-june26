import Foundation
import Supabase

/// Best-effort email notification for team invitations.
///
/// Flow (durable-first, mirrors `SupabaseSupportRepository`):
///   1. The app calls the `create_invitation` RPC — the invitation row is the
///      durable path and must never be lost.
///   2. Best-effort: invoke the `send-invitation-email` edge function, which
///      emails the invitee via Resend.
///
/// A failure here does NOT fail the invite — the invitee can always accept
/// in-app by signing in with the invited email. The returned status
/// ("sent" / "failed" / "unconfigured") lets the UI report delivery honestly.
nonisolated struct InvitationEmailService: Sendable {
    static let edgeFunctionName = "send-invitation-email"

    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    /// Invokes the edge function and returns the reported email status.
    /// Never throws — delivery is best-effort.
    func send(invitationId: UUID) async -> String {
        guard provider.isConfigured else { return "unconfigured" }
        guard let session = try? await provider.client.auth.session else {
            return "failed"
        }

        let base = AppConfig.supabaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/functions/v1/\(Self.edgeFunctionName)") else {
            return "unknown"
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["invitationId": invitationId.uuidString.lowercased()]
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return "unknown" }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (200..<300).contains(http.statusCode),
               let status = body?["emailStatus"] as? String {
                print("[InvitationEmail] id=\(invitationId.uuidString.lowercased()) emailStatus=\(status)")
                return status
            }
            print("[InvitationEmail] id=\(invitationId.uuidString.lowercased()) notify HTTP \(http.statusCode)")
            return "failed"
        } catch {
            print("[InvitationEmail] id=\(invitationId.uuidString.lowercased()) notify error=\(error.localizedDescription)")
            return "failed"
        }
    }
}
