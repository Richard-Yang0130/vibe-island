import CodexBarCore
import Foundation
import os
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreWidgetSnapshotLoadingTests {
    @Test
    func `delayed cache load stays off main actor coalesces and preserves quota with latest state`() async throws {
        let suite = "WidgetSnapshotLoading-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        var saved: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { saved.append($0) }
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 28, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .claude)
        store.persistWidgetSnapshot(reason: "prime-isolated-cache")
        await store.widgetSnapshotPersistTask?.value
        let cached = try #require(saved.last)
        saved.removeAll()
        store.lastQueuedWidgetSnapshot = nil
        store.snapshots.removeValue(forKey: .claude)

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let observations = OSAllocatedUnfairLock(initialState: (loads: 0, ranOnMain: false))
        store._test_widgetSnapshotLoadOverride = {
            observations.withLock { $0.loads += 1; $0.ranOnMain = Thread.isMainThread }
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return cached
        }
        store.persistWidgetSnapshot(reason: "startup")
        let waitForStart: @Sendable () -> Bool = { started.wait(timeout: .now() + 2) == .success }
        let didStart = await Task.detached(operation: waitForStart).value
        #expect(didStart)
        #expect(!observations.withLock { $0.ranOnMain })
        #expect(saved.isEmpty)
        let heartbeat = await Task { @MainActor in true }.value
        #expect(heartbeat)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 37, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        for _ in 0..<100 {
            store.persistWidgetSnapshot(reason: "coalesced")
        }
        #expect(observations.withLock { $0.loads } == 1)
        #expect(saved.isEmpty)
        release.signal()
        await store.widgetSnapshotPersistTask?.value
        #expect(saved.count == 1)
        #expect(saved.last?.entries.first { $0.provider == .claude }?.primary?.usedPercent == 28)
        #expect(saved.last?.entries.first { $0.provider == .codex }?.primary?.usedPercent == 37)
        store.persistWidgetSnapshot(reason: "ready")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved.count == 2)
        #expect(observations.withLock { $0.loads } == 1)
    }

    @Test
    func `failed initial load still saves and is not retried on each refresh`() async throws {
        let suite = "WidgetSnapshotLoading-nil-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: SettingsStore(
                userDefaults: defaults,
                configStore: testConfigStore(suiteName: suite),
                zaiTokenStore: NoopZaiTokenStore(),
                syntheticTokenStore: NoopSyntheticTokenStore()))
        let loads = OSAllocatedUnfairLock(initialState: 0)
        store._test_widgetSnapshotLoadOverride = {
            loads.withLock { $0 += 1 }
            return nil
        }
        var saves = 0
        store._test_widgetSnapshotSaveOverride = { _ in saves += 1 }
        store.persistWidgetSnapshot(reason: "startup")
        await store.widgetSnapshotPersistTask?.value
        store.persistWidgetSnapshot(reason: "refresh")
        await store.widgetSnapshotPersistTask?.value
        #expect(saves == 2)
        #expect(loads.withLock { $0 } == 1)
    }
}
