import Foundation
import Testing
import UIKit
@testable import VineTrack

@MainActor
struct CanopyReferenceImageRepositoryTests {
    final class Remote: CanopyReferenceImageRemote, @unchecked Sendable {
        var configuration: CanopyReferenceConfiguration
        var payloads: [String: Data]
        var failingPaths: Set<String> = []
        var configError: Error?
        private(set) var configRequests = 0
        var imageRequests: [String] = []

        init(images: [String: CanopyReferenceRemoteImage], payloads: [String: Data]) {
            configuration = CanopyReferenceConfiguration(
                bucket: "guide-images",
                configUpdatedAt: "config-v1",
                images: images
            )
            self.payloads = payloads
        }

        func fetchConfiguration() async throws -> CanopyReferenceConfiguration {
            configRequests += 1
            if let configError { throw configError }
            return configuration
        }

        func downloadImage(bucket: String, path: String) async throws -> Data {
            imageRequests.append(path)
            if failingPaths.contains(path) { throw TestError.unavailable }
            return payloads[path] ?? Data()
        }
    }

    enum TestError: Error { case unavailable }

    private let validA = Data("IMG-a".utf8)
    private let validB = Data("IMG-b".utf8)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanopyReferenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repository(directory: URL, remote: Remote) -> CanopyReferenceImageRepository {
        CanopyReferenceImageRepository(
            baseDirectory: directory,
            remote: remote,
            validator: { data in data.starts(with: Data("IMG-".utf8)) }
        )
    }

    @Test("Fresh custom image downloads once, persists, and unchanged relaunch downloads zero images")
    func freshInstallAndRelaunch() async throws {
        let root = try directory()
        let image = CanopyReferenceRemoteImage(path: "canopy-reference/vsp-small.png", updatedAt: "v1")
        let remote = Remote(images: [CanopyReferenceImageSlot.vspSmall.rawValue: image], payloads: [image.path: validA])
        let first = repository(directory: root, remote: remote)

        await first.refresh()
        #expect(remote.imageRequests == [image.path])
        #expect(first.localImageURL(for: .vspSmall) != nil)

        let restarted = repository(directory: root, remote: remote)
        await restarted.refresh()
        #expect(remote.imageRequests == [image.path])
        #expect(restarted.localImageURL(for: .vspSmall) != nil)
    }

    @Test("Repeated Spray Setup entry performs one config refresh and no repeated image download")
    func oncePerSession() async throws {
        let root = try directory()
        let image = CanopyReferenceRemoteImage(path: "canopy-reference/vsp-medium.png", updatedAt: "v1")
        let remote = Remote(images: [CanopyReferenceImageSlot.vspMedium.rawValue: image], payloads: [image.path: validA])
        let subject = repository(directory: root, remote: remote)

        await subject.refreshOncePerSession()
        await subject.refreshOncePerSession()
        await subject.refreshOncePerSession()

        #expect(remote.configRequests == 1)
        #expect(remote.imageRequests.count == 1)
    }

    @Test("One changed slot downloads exactly one image while seven unchanged slots make zero requests")
    func selectiveReplacement() async throws {
        let root = try directory()
        let initial = Dictionary(uniqueKeysWithValues: CanopyReferenceImageSlot.allCases.enumerated().map { index, slot in
            (slot.rawValue, CanopyReferenceRemoteImage(path: "canopy-reference/\(index).png", updatedAt: "v1"))
        })
        let payloads = Dictionary(uniqueKeysWithValues: initial.values.map { ($0.path, validA) })
        let remote = Remote(images: initial, payloads: payloads)
        let subject = repository(directory: root, remote: remote)
        await subject.refresh()
        #expect(remote.imageRequests.count == 8)

        remote.imageRequests.removeAll()
        await subject.refresh()
        #expect(remote.imageRequests.isEmpty)

        var changed = initial
        let replacement = CanopyReferenceRemoteImage(path: "canopy-reference/replacement.png", updatedAt: "v2")
        changed[CanopyReferenceImageSlot.sprawlLarge.rawValue] = replacement
        remote.configuration = CanopyReferenceConfiguration(bucket: "guide-images", configUpdatedAt: "config-v2", images: changed)
        remote.payloads[replacement.path] = validB
        await subject.refresh()
        #expect(remote.imageRequests == [replacement.path])
    }

    @Test("Offline relaunch retains custom image while fresh offline install has no custom file")
    func offlineFallbacks() async throws {
        let root = try directory()
        let image = CanopyReferenceRemoteImage(path: "canopy-reference/full.png", updatedAt: "v1")
        let remote = Remote(images: [CanopyReferenceImageSlot.vspFull.rawValue: image], payloads: [image.path: validA])
        await repository(directory: root, remote: remote).refresh()

        let offline = Remote(images: [:], payloads: [:])
        offline.configError = TestError.unavailable
        let relaunched = repository(directory: root, remote: offline)
        await relaunched.refresh()
        #expect(relaunched.localImageURL(for: .vspFull) != nil)

        let freshOffline = repository(directory: try directory(), remote: offline)
        await freshOffline.refresh()
        #expect(freshOffline.localImageURL(for: .vspFull) == nil)
        for slot in CanopyReferenceImageSlot.allCases {
            #expect(UIImage(named: slot.bundledAssetName) != nil)
        }
    }

    @Test("Failed or corrupt replacement retains the prior valid image")
    func invalidReplacementRetainsPrevious() async throws {
        let root = try directory()
        let original = CanopyReferenceRemoteImage(path: "canopy-reference/original.png", updatedAt: "v1")
        let remote = Remote(images: [CanopyReferenceImageSlot.sprawlSmall.rawValue: original], payloads: [original.path: validA])
        let subject = repository(directory: root, remote: remote)
        await subject.refresh()
        let originalURL = subject.localImageURL(for: .sprawlSmall)

        let failed = CanopyReferenceRemoteImage(path: "canopy-reference/failed.png", updatedAt: "v2")
        remote.configuration = CanopyReferenceConfiguration(bucket: "guide-images", configUpdatedAt: "v2", images: [CanopyReferenceImageSlot.sprawlSmall.rawValue: failed])
        remote.failingPaths = [failed.path]
        await subject.refresh()
        #expect(subject.localImageURL(for: .sprawlSmall) == originalURL)

        remote.failingPaths = []
        remote.payloads[failed.path] = Data("corrupt".utf8)
        await subject.refresh()
        #expect(subject.localImageURL(for: .sprawlSmall) == originalURL)
        #expect(subject.manifestEntry(for: .sprawlSmall)?.remotePath == original.path)
    }

    @Test("Admin reset removes custom identity and immediately restores bundled fallback")
    func adminReset() async throws {
        let root = try directory()
        let image = CanopyReferenceRemoteImage(path: "canopy-reference/reset.png", updatedAt: "v1")
        let remote = Remote(images: [CanopyReferenceImageSlot.sprawlFull.rawValue: image], payloads: [image.path: validA])
        let subject = repository(directory: root, remote: remote)
        await subject.refresh()
        let oldURL = subject.localImageURL(for: .sprawlFull)
        #expect(oldURL != nil)

        remote.configuration = CanopyReferenceConfiguration(bucket: "guide-images", configUpdatedAt: "v2", images: [:])
        await subject.refresh()
        #expect(subject.localImageURL(for: .sprawlFull) == nil)
        #expect(subject.manifestEntry(for: .sprawlFull) == nil)
        #expect(oldURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(UIImage(named: CanopyReferenceImageSlot.sprawlFull.bundledAssetName) != nil)
    }

    @Test("The shared eight keys and canopy calculations remain unchanged")
    func slotsAndCalculationParity() {
        #expect(Set(CanopyReferenceImageSlot.allCases.map(\.rawValue)) == [
            "canopy.vsp.small", "canopy.vsp.medium", "canopy.vsp.large", "canopy.vsp.full",
            "canopy.sprawl.small", "canopy.sprawl.medium", "canopy.sprawl.large", "canopy.sprawl.full",
        ])
        #expect(CanopyWaterRate.litresPer100m(type: .vsp, size: .full, density: .high) == 75)
        #expect(CanopyWaterRate.litresPer100m(type: .sprawl, size: .full, density: .high) == 90)
    }
}
