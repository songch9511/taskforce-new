import AppKit
import Auth
import Foundation
import SwiftUI
import Supabase
import Testing
@testable import TaskforceKit
@testable import Taskforce

/// Writes synthetic offscreen SwiftUI previews for visual review; these are fixtures, not live app captures.
@Suite(.serialized)
@MainActor
struct LauncherPresentationFixtureRendersTests {
    @Test func writesLightAndDarkFixtureRenders() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaskforceLauncherPresentationFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let appearances: [(ColorScheme, String)] = [(.light, "light"), (.dark, "dark")]
        let model = try fixtureModel()
        #expect(model.isSignedIn)
        #expect(model.items.count > 1)
        #expect(model.bodyState == .list)

        for (scheme, appearance) in appearances {
            try await render(LauncherRootView(model: model), name: "fixture-launcher-collapsed-\(appearance)", scheme: scheme, to: directory)
        }

        let demo = try #require(model.items.first { $0.inlineDetailActionID == SampleData.demoID })
        for (scheme, appearance) in appearances {
            try await render(
                LauncherRootView(model: model),
                name: "fixture-launcher-expanded-sources-\(appearance)",
                scheme: scheme,
                to: directory,
                afterInitialLayout: { model.openDetail(for: demo) }
            )
            #expect(model.detailTarget?.action.id == SampleData.demoID)
            model.back()

            let initialModel = try fixtureModel()
            let initialDemo = try #require(initialModel.items.first { $0.inlineDetailActionID == SampleData.demoID })
            initialModel.openDetail(for: initialDemo)
            #expect(initialModel.detailTarget?.action.id == SampleData.demoID)
            try await render(
                LauncherRootView(model: initialModel),
                name: "fixture-launcher-expanded-initial-\(appearance)",
                scheme: scheme,
                to: directory
            )
        }

        let settings = VStack(alignment: .leading, spacing: 8) {
            Text("Fixture · Settings / Task List")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Task List")
                .font(.system(size: 22, weight: .semibold))
            SectionDisplaySettingsPane(preferences: .all)
        }
        .padding(20)
        .frame(width: 752, height: 440, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        for (scheme, appearance) in appearances {
            try await render(settings, name: "fixture-settings-section-counts-\(appearance)", scheme: scheme, to: directory)
        }

        let about = AboutSettingsPane(buildInfo: AboutBuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "23",
            AboutBuildInfo.releaseChannelKey: "Development",
            AboutBuildInfo.sourceCommitKey: "Not available",
            AboutBuildInfo.buildTimeUTCKey: "Not available",
        ]))
        for (scheme, appearance) in appearances {
            try await render(about, name: "fixture-settings-about-\(appearance)", scheme: scheme, to: directory)
        }

        let names = [
            "fixture-launcher-collapsed", "fixture-launcher-expanded-sources", "fixture-launcher-expanded-initial",
            "fixture-settings-section-counts", "fixture-settings-about"
        ]
        #expect(names.allSatisfy { name in
            appearances.allSatisfy { appearance in
                FileManager.default.fileExists(atPath: directory.appending(path: "\(name)-\(appearance.1).png").path)
            }
        })
        print("Wrote synthetic fixture renders to \(directory.path)")
    }

    private func render<Content: View>(
        _ view: Content,
        name: String,
        scheme: ColorScheme,
        to directory: URL,
        afterInitialLayout: (() -> Void)? = nil
    ) async throws {
        let size = NSSize(width: 760, height: 480)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        window.contentView = hosting
        window.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        afterInitialLayout?()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(240))
        window.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.close()
            throw FixtureRenderError.failed(name)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            window.close()
            throw FixtureRenderError.failed(name)
        }
        try data.write(to: directory.appending(path: "\(name).png"), options: .atomic)
        window.close()
    }

    private func fixtureModel() throws -> LauncherModel {
        let config = AppConfig(
            supabaseURL: URL(string: "https://taskforce-fixture.invalid")!,
            supabaseKey: "fixture-only",
            appGroupID: "group.test.taskforce.fixture",
            apiBaseURL: URL(string: "https://taskforce-api-fixture.invalid")!
        )
        let supabase = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(storage: FixtureAuthStorage(), autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(session: URLSession(configuration: .ephemeral))
            )
        )
        let session = SessionStore(auth: supabase.auth)
        session.apply(event: .signedOut, session: nil)
        let services = AppServices(config: config, supabase: supabase, session: URLSession(configuration: .ephemeral))
        let account = AccountStore(services: services, session: session)
        let defaults = UserDefaults(suiteName: "LauncherPresentationFixture-\(UUID().uuidString)")!
        let model = LauncherModel(session: session, services: services, account: account, displayPreferencesDefaults: defaults)
        guard let now = model.now else { throw FixtureRenderError.missingNowStore }
        now.sampleMode = true
        let evidence = SampleData.evidence
        now.applySample(
            SampleData.now,
            doneToday: SampleData.doneToday,
            evidence: evidence,
            sourceServices: evidence.mapValues { $0.withoutReceipts.services }
        )
        return model
    }
}

private enum FixtureRenderError: Error {
    case failed(String)
    case missingNowStore
}

private final class FixtureAuthStorage: AuthLocalStorage, @unchecked Sendable {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}
