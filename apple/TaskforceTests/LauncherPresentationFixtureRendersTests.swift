import AppKit
import Auth
import Foundation
import SwiftUI
import Supabase
import Testing
import TaskforceUI
@testable import TaskforceKit
@testable import Taskforce

/// Writes synthetic offscreen SwiftUI previews for visual review; these are fixtures, not live app captures.
@Suite(.serialized)
@MainActor
struct LauncherPresentationFixtureRendersTests {
    @Test func searchSuggestionsKeepEqualTopAndSideInsets() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaskforceLauncherPresentationFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (query, label) in [("오", "korean"), ("unmatched task", "english")] {
            let model = try fixtureModel()
            model.now?.applySample(NowResponse(now: [], confirmations: [], weeklyCheck: nil), doneToday: [], evidence: [:])
            model.text = query
            #expect(model.items == [.addAction(query), .ask(query)])
            for (scheme, appearance) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                let name = "fixture-search-insets-\(label)-\(appearance)"
                try await render(LauncherListPane(model: model), name: name, scheme: scheme, to: directory)
                let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
                let bitmap = try #require(NSBitmapImageRep(data: data))
                let scale = CGFloat(bitmap.pixelsWide) / 760
                let background = try #require(bitmap.colorAt(x: 0, y: Int(100 * scale)))
                let top = try #require((0..<Int(36 * scale)).first {
                    bitmap.colorAt(x: bitmap.pixelsWide / 2, y: $0) != background
                })
                let left = try #require((0..<Int(36 * scale)).first {
                    bitmap.colorAt(x: $0, y: Int(26 * scale)) != background
                })
                #expect(top == left, "The first selected suggestion must have equal top and side padding")
                #expect(top == Int(8 * scale))
                try await render(LauncherRootView(model: model), name: "fixture-search-\(label)-\(appearance)", scheme: scheme, to: directory)
            }
        }
    }

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

        let settings = VStack(alignment: .leading, spacing: 0) {
            Text("Task List")
                .font(TFFont.pageTitle)
                .foregroundStyle(TFColor.textPrimary)
                .frame(width: MacSettingsView.column, height: 28, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 26)
            SectionDisplaySettingsPane(preferences: .all)
        }
        .frame(
            width: MacSettingsView.windowSize.width - 2 * TFSpace.xs - MacSettingsView.sidebarWidth,
            height: 404,
            alignment: .topLeading
        )
        .background(TFColor.settingsContent)
        for (scheme, appearance) in appearances {
            try await render(settings, name: "fixture-settings-section-counts-\(appearance)", scheme: scheme, to: directory)
        }

        let about = AboutSettingsPane(buildInfo: AboutBuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "23",
            AboutBuildInfo.releaseChannelKey: "Development",
            AboutBuildInfo.sourceCommitKey: "0123456789abcdef0123456789abcdef01234567",
            AboutBuildInfo.buildTimeUTCKey: "2026-10-08T00:00:00Z",
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

    @Test func writesFullSettingsShellFixturesWithStableSidebar() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaskforceLauncherPresentationFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = UserDefaults.standard.object(forKey: SettingsOpener.tabKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: SettingsOpener.tabKey) }
            else { UserDefaults.standard.removeObject(forKey: SettingsOpener.tabKey) }
        }
        let userID = UUID()
        let user = User(id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "fixture@example.com", createdAt: Date(), updatedAt: Date())
        let authSession = Session(accessToken: "fixture-only", tokenType: "bearer", expiresIn: 3600,
                                  expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970,
                                  refreshToken: "fixture-only", user: user)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsFixtureURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }
        let config = AppConfig(supabaseURL: URL(string: "https://settings-fixture.invalid")!, supabaseKey: "fixture-only",
                               appGroupID: "group.test.settings.fixture", apiBaseURL: URL(string: "https://settings-fixture.invalid")!)
        let supabase = SupabaseClient(supabaseURL: config.supabaseURL, supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(storage: SettingsFixtureAuthStorage(data: try AuthClient.Configuration.jsonEncoder.encode(authSession)),
                            autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(session: urlSession)))
        let session = SessionStore(auth: supabase.auth)
        session.apply(event: .signedIn, session: authSession)
        let services = AppServices(config: config, supabase: supabase, session: urlSession)
        let account = AccountStore(services: services, session: session)
        account.useSampleData(connections: [])
        let runs = RunStore(services: services, session: session)
        runs.applySample(credits: .available(CreditsSummary(available: 480, reserved: 20,
            used: .init(credits: 120, since: Date()), draftEstimateCredits: 10), checkedAt: Date()), runs: [], steps: [], drafts: [])
        // Prove these reads resolve locally before using them as screenshot evidence.
        #expect(try await services.api.billing().label == "Monthly subscription")
        #expect(try await services.api.aiBudget().remainingUSD == Decimal(string: "2.25"))

        for (scheme, appearance) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            UserDefaults.standard.set(MacSettingsTab.keyboardShortcuts.rawValue, forKey: SettingsOpener.tabKey)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: MacSettingsView().environment(session).environment(account).environment(runs)
                .environment(\.services, services).environment(\.colorScheme, scheme))
            window.contentView = host
            window.setFrame(NSRect(x: 0, y: 0, width: 760, height: 480), display: true)
            defer { window.close() }
            var baseline: [NSColor]?
            var baselineSize: NSSize?
            for tab in [MacSettingsTab.keyboardShortcuts, .about, .account, .usage] {
                UserDefaults.standard.set(tab.rawValue, forKey: SettingsOpener.tabKey)
                try await Task.sleep(for: .milliseconds(500))
                window.displayIfNeeded()
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                #expect(window.attachedSheet == nil, "Account must remain inline in the same shell")
                #expect(window.frame.width == 760)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: directory.appending(path: "fixture-settings-shell-\(tab.rawValue)-\(appearance).png"))
                // Header strip includes both shell edges and the sidebar divider, above selectable rows.
                // An intrinsic-width expansion shifts these pixels even when the outer window stays fixed.
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                let strip = (0..<204).compactMap { bitmap.colorAt(x: Int(CGFloat($0) * scale), y: Int(60 * scale)) }
                if let baseline, let baselineSize {
                    #expect(host.bounds.size == baselineSize)
                    #expect(strip == baseline, "Sidebar header and divider must not move when switching to \(tab)")
                } else {
                    baseline = strip
                    baselineSize = host.bounds.size
                }
            }
        }
        print("Wrote synthetic full settings shells to \(directory.path)")
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

private final class SettingsFixtureAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data
    init(data: Data) { self.data = data }
    func store(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        data = value
    }
    func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
    // Auth migrates old storage keys; removing them must not remove this fixture session.
    func remove(key: String) throws {}
}

/// Every request on this fixture session is intercepted; unexpected routes fail without network access.
private final class SettingsFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, request.httpMethod == "GET" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let allowance = #"{"cap_usd":3,"confirmed_usd":0.5,"reserved_usd":0.25,"pending_count":1,"remaining_usd":2.25,"status":"available"}"#
        let body: String
        if url.path.hasSuffix("/billing") {
            body = #"{"status":"active","plan":"monthly","can_use_ai":true,"can_checkout":false,"current_period_ends_at":"2026-11-08T00:00:00Z","allowance_resets_at":"2026-11-01T00:00:00Z","ai_allowance":\#(allowance)}"#
        } else if url.path.hasSuffix("/ai-budget") {
            body = allowance
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
