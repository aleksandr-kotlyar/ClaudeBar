import Testing
import Foundation
@testable import Domain

@Suite
struct RefreshIntervalTests {
    @Test
    func `seconds maps each option onto its poll interval`() {
        #expect(RefreshInterval.off.seconds == nil)
        #expect(RefreshInterval.oneMinute.seconds == 60)
        #expect(RefreshInterval.fiveMinutes.seconds == 300)
        #expect(RefreshInterval.fifteenMinutes.seconds == 900)
    }

    @Test
    func `isEnabled is false only for off`() {
        #expect(RefreshInterval.off.isEnabled == false)
        #expect(RefreshInterval.oneMinute.isEnabled == true)
        #expect(RefreshInterval.fiveMinutes.isEnabled == true)
        #expect(RefreshInterval.fifteenMinutes.isEnabled == true)
    }

    @Test
    func `label matches the picker copy`() {
        #expect(RefreshInterval.off.label == "Off")
        #expect(RefreshInterval.oneMinute.label == "1 min")
        #expect(RefreshInterval.fiveMinutes.label == "5 min")
        #expect(RefreshInterval.fifteenMinutes.label == "15 min")
    }

    @Test
    func `migrating returns off when background sync is disabled`() {
        #expect(RefreshInterval.migrating(enabled: false, storedSeconds: 60) == .off)
        #expect(RefreshInterval.migrating(enabled: false, storedSeconds: 900) == .off)
    }

    @Test
    func `migrating snaps a stored interval to the nearest supported option`() {
        // Retired 30s / 2m options and below-floor values snap up to 1 minute.
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 30) == .oneMinute)
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 60) == .oneMinute)
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 120) == .oneMinute)
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 300) == .fiveMinutes)
        #expect(RefreshInterval.migrating(enabled: true, storedSeconds: 900) == .fifteenMinutes)
    }

    @Test
    func `allCases lists the options in picker order`() {
        #expect(RefreshInterval.allCases == [.off, .oneMinute, .fiveMinutes, .fifteenMinutes])
    }
}
