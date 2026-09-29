import Testing
@testable import VineTrack

@Suite("Biometric background grace")
@MainActor
struct BiometricBackgroundGraceTests {
    @Test func thresholdAndDisabled() {
        for seconds in [30, 300, 3_540, 3_599] {
            #expect(!BiometricBackgroundGrace.shouldLock(elapsed: .seconds(seconds), isEnabled: true))
        }
        #expect(BiometricBackgroundGrace.shouldLock(elapsed: .seconds(3_600), isEnabled: true))
        #expect(BiometricBackgroundGrace.shouldLock(elapsed: .seconds(3_601), isEnabled: true))
        #expect(!BiometricBackgroundGrace.shouldLock(elapsed: .seconds(3_601), isEnabled: false))
    }
}
