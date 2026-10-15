import Foundation

/// Uses captured credentials for one authenticated incarnation. Scope is rechecked by the client after every await.
/// Not registered with the production Save/Start paths while the independent operational gate is closed.
@MainActor final class SprayPlanningHTTPTransport: SprayPlanningTransport {
    private let baseURL: URL
    private let apiKey: String
    private let accessToken: String
    init(baseURL: URL, apiKey: String, accessToken: String) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.accessToken = accessToken
    }
    func call(_ rpc: String, body: Data) async throws -> (status: Int, data: Data) {
        let allowed = SprayPlanningProtocol.Kind.allCases.map(\.rpc) + ["get_spray_planning_capability_v1", "get_spray_planning_recovery_v1"]
        guard allowed.contains(rpc) else { throw SprayPlanningProtocol.Failure.invalidRequest }
        var request = URLRequest(url: baseURL.appendingPathComponent("rest/v1/rpc/" + rpc))
        request.httpMethod = "POST"; request.timeoutInterval = 30; request.httpBody = body
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SprayPlanningProtocol.Failure.unavailable }
        return (http.statusCode, data)
    }
}
