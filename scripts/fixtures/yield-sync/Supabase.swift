import Foundation
public struct SupabaseClient { public init() {}
    public func rpc<T: Encodable>(_ name: String, params: T) -> Query { Query() }
}
public struct Query {
    public func execute<T: Decodable>() async throws -> Response<T> { throw URLError(.notConnectedToInternet) }
}
public struct Response<T> { public let value: T }
