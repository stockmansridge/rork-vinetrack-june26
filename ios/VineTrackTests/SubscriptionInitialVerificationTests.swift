import Foundation
import RevenueCat
import Testing
@testable import VineTrack

@MainActor
struct SubscriptionInitialVerificationTests {
    private enum Offline: Error { case unavailable }

    private func info(expires: String?) throws -> CustomerInfo {
        let subscription = expires.map { "\"product\":{\"expires_date\":\"\($0)\",\"purchase_date\":\"2020-01-01T00:00:00Z\",\"original_purchase_date\":\"2020-01-01T00:00:00Z\",\"store\":\"app_store\",\"period_type\":\"normal\",\"is_sandbox\":true}" } ?? ""
        let entitlement = expires.map { "\"pro\":{\"expires_date\":\"\($0)\",\"purchase_date\":\"2020-01-01T00:00:00Z\",\"product_identifier\":\"product\"}" } ?? ""
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CustomerInfo.self, from: Data("""
        {"schema_version":"3","request_date":"2026-10-29T00:00:00Z","subscriber":{
        "original_app_user_id":"synthetic-verification","first_seen":"2020-01-01T00:00:00Z",
        "original_application_version":"1","subscriptions":{\(subscription)},"entitlements":{\(entitlement)},"non_subscriptions":{}}}
        """.utf8))
    }

    @Test func initialVerificationIsUnresolvedUntilCurrentFetchFinishes() async {
        var service: SubscriptionService!
        var fetched = false
        service = SubscriptionService(identifyCustomer: { _ in
            #expect(service.isVerifyingInitialCustomer)
            #expect(!service.hasResolvedStatus)
        }, fetchInitialCustomer: {
            fetched = true
            #expect(service.isVerifyingInitialCustomer)
            #expect(!service.hasResolvedStatus)
            throw Offline.unavailable
        })
        await service.login(userId: UUID(), userCreatedAt: Date(timeIntervalSince1970: 0))
        #expect(fetched)
        #expect(!service.isVerifyingInitialCustomer)
        #expect(service.hasResolvedStatus)
        #expect(!service.hasAccess)
        #expect(!service.isPurchasing && !service.isRestoring)
    }

    @Test func oldLoginFailureCannotOverwriteNewIdentityVerification() async throws {
        let verified = try info(expires: "2099-01-01T00:00:00Z")
        let oldUser = UUID(), newUser = UUID()
        var service: SubscriptionService!
        service = SubscriptionService(identifyCustomer: { user in
            if user == oldUser {
                await service.login(userId: newUser, userCreatedAt: Date(timeIntervalSince1970: 0))
                throw Offline.unavailable
            }
        }, fetchInitialCustomer: { verified })
        await service.login(userId: oldUser, userCreatedAt: Date(timeIntervalSince1970: 0))
        #expect(service.status == .subscribed)
        #expect(service.isSubscribed)
        #expect(service.hasResolvedStatus)
    }

    @Test func currentEntitledExpiredAndUnentitledResultsResolveWithoutTransaction() async throws {
        for expiry in [Optional("2099-01-01T00:00:00Z"), Optional("2020-02-01T00:00:00Z"), nil] {
            let current = try info(expires: expiry)
            let service = SubscriptionService(identifyCustomer: { _ in }, fetchInitialCustomer: { current })
            await service.login(userId: UUID(), userCreatedAt: Date(timeIntervalSince1970: 0))
            #expect(service.hasResolvedStatus)
            #expect(service.isSubscribed == (expiry == "2099-01-01T00:00:00Z"))
            #expect(service.hasAccess == (expiry == "2099-01-01T00:00:00Z"))
            #expect(!service.isPurchasing && !service.isRestoring)
        }
    }
}
