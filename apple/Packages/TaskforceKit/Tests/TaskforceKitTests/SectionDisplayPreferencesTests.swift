import Foundation
import Testing
@testable import TaskforceKit

struct SectionDisplayPreferencesTests {
    @Test func preferencesPersistForEverySection() {
        let suite = "section-display-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = SectionDisplayPreferences(review: .five, inProgress: .ten, toDo: .twenty, doneToday: .fifty)
        preferences.save(to: defaults)

        #expect(SectionDisplayPreferences.load(from: defaults) == preferences)
    }

    @Test func missingAndInvalidValuesDefaultToAllPerSection() {
        let suite = "section-display-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(3, forKey: "\(SectionDisplayPreferences.defaultsKey).review")
        defaults.set(20, forKey: "\(SectionDisplayPreferences.defaultsKey).toDo")
        defaults.set(5, forKey: "\(SectionDisplayPreferences.defaultsKey).doneToday")

        let preferences = SectionDisplayPreferences.load(from: defaults)

        #expect(preferences.review == .all)
        #expect(preferences.inProgress == .all)
        #expect(preferences.toDo == .twenty)
        #expect(preferences.doneToday == .five)
    }

    @Test func sectionCapsUseExplicitCountsWithoutChangingServerContract() {
        let preferences = SectionDisplayPreferences(review: .five, doneToday: .ten)
        let caps = SectionCaps(limits: SectionLimits(review: 1, inProgress: 2, toDo: 3), displayPreferences: preferences)

        #expect(caps.fold(.review, count: 8) == .capped(visible: 5, hidden: 3))
        #expect(caps.fold(.inProgress, count: 8) == .all)
        #expect(caps.fold(.doneToday, count: 12) == .capped(visible: 10, hidden: 2))
        #expect(SectionLimits.standard == SectionLimits(review: 2, inProgress: 5, toDo: 5))
    }

    @Test func applyingPreferencesReplacesExpandedState() {
        var caps = SectionCaps()
        caps.expand(.review)
        caps.apply(displayPreferences: SectionDisplayPreferences(review: .five))

        #expect(caps.fold(.review, count: 8) == .capped(visible: 5, hidden: 3))
        #expect(caps.fold(.inProgress, count: 8) == .all)
    }
}
