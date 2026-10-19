import AppKit
import Auth
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
import TaskforceUI

/// 로그인 화면 (OA 로그인 계약 5.7 · 11.2, 사용자 승인 2026-10-19): 버튼 순서 Apple → Google, 제목 · 법률 줄, Google 전용 안내 · 연락 링크 0.
@MainActor
struct SignInScreenTests {
    @Test func appleComesFirstThenGoogleAtTheSameSize() {
        let screen = SignInScreen.make(appleAvailable: true, googleAvailable: true)
        #expect(screen.buttons == [.apple, .google])
        #expect(screen.unavailable == nil)
        #expect(SignInScreen.make(appleAvailable: true, googleAvailable: false).buttons == [.apple])
        #expect(SignInScreen.make(appleAvailable: false, googleAvailable: true).buttons == [.google])
    }

    /// 설정이 하나도 없으면(Debug 빌드) 한 줄
    @Test func withoutAnyConfigurationOneLineSaysSo() {
        let screen = SignInScreen.make(appleAvailable: false, googleAvailable: false)
        #expect(screen.buttons.isEmpty)
        #expect(screen.unavailable == "Sign-in is unavailable in this build.")
    }

    /// DS SignIn의 글자: 제목 · Sign in with Apple(시스템 버튼 · 런처 행) · Continue with Google · 법률 한 줄
    @Test func theScreenSpeaksTheDesignSystemWords() {
        #expect(SignInCopy.title == "Sign in to Taskforce")
        #expect(SignInCopy.appleTitle == "Sign in with Apple")
        #expect(SignInCopy.googleTitle == "Continue with Google")
        #expect(SignInWithGoogleButton.title == "Continue with Google")
        #expect(SignInCopy.legalLine == "By continuing you agree to the Terms and Privacy Policy.")
    }

    /// 법률 한 줄 안의 두 낱말이 링크다
    @Test func theLegalLineLinksTermsAndPrivacyPolicy() {
        let text = SignInView.legalText(SignInCopy.legalLine)
        var links: [String: URL] = [:]
        for run in text.runs {
            if let link = run.link { links[String(text[run.range].characters)] = link }
        }
        #expect(links == ["Terms": LegalLinks.terms, "Privacy Policy": LegalLinks.privacy])
    }

    /// 화면이 실제로 그려진다: 세션 환경 아래에서 레이아웃이 비어 있지 않다 (Apple 시스템 버튼 포함)
    @Test func theScreenLaysOutWithoutASession() throws {
        let session = SessionStore(auth: AuthClient(url: URL(string: "https://signin-screen.invalid/auth/v1")!, localStorage: NoStorage(),
            fetch: { _ in Issue.record("Rendering must not contact an auth server"); throw URLError(.badURL) }, autoRefreshToken: false))
        let host = NSHostingView(rootView: SignInView().environment(session))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 420)
        host.layoutSubtreeIfNeeded()
        // 제목 · 버튼 · 법률 줄이 들어 있으면 내용이 있는 크기다 (비어 있으면 0)
        #expect(host.fittingSize.width >= 200 && host.fittingSize.height >= 150, "\(host.fittingSize)")
    }

    /// Release 설정의 공개 값(Services ID · Return URL)을 앱이 받아들인다: xcconfig의 `/$()/`를 `//`로 읽은 값이 설정 검사를 통과한다.
    /// 서버 route 경로(`/api/v1/apple/return`)와 Services ID가 바뀌면 여기서 먼저 걸린다
    @Test func theReleaseConfigurationHoldsAUsableServicesIDAndReturnURL() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: apple.appending(path: "Config/Release.xcconfig"), encoding: .utf8)
        func value(_ key: String) -> String? {
            text.split(separator: "\n").lazy
                .filter { !$0.hasPrefix("//") }
                .compactMap { line -> String? in
                    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return parts.count == 2 && parts[0] == key ? parts[1].replacingOccurrences(of: "/$()/", with: "//") : nil
                }.first
        }
        let servicesID = try #require(value("APPLE_SERVICES_ID"))
        let returnURL = try #require(value("APPLE_WEB_RETURN_URL"))
        let config = try #require(AppleWebSignInConfig(infoDictionary: ["AppleServicesID": servicesID, "AppleWebReturnURL": returnURL]))
        #expect(config.servicesID == "dev.taskforcelabs.taskforce.signin")
        #expect(config.returnURL.absoluteString == "https://api.taskforcelabs.dev/api/v1/apple/return")
        // 서버 중계 route가 같은 경로에 있다
        let route = apple.deletingLastPathComponent().appending(path: "src/app/api/v1/apple/return/route.ts")
        #expect(FileManager.default.fileExists(atPath: route.path))
    }

    /// Info.plist가 두 값을 빌드 설정에서 읽는다 (권한 파일이 아니다)
    @Test func theInfoPlistReadsBothValuesFromBuildSettings() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: apple.appending(path: "Taskforce/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        #expect(plist["AppleServicesID"] as? String == "$(APPLE_SERVICES_ID)")
        #expect(plist["AppleWebReturnURL"] as? String == "$(APPLE_WEB_RETURN_URL)")
        // 치환되지 않은 값은 설정으로 받아들이지 않는다
        #expect(AppleWebSignInConfig(infoDictionary: plist) == nil)
    }

    /// 예전 Google 전용 문구 · 연락 링크는 앱 소스 어디에도 남지 않았다 (Release `strings` 검사가 바이너리에서 한 번 더 본다)
    @Test func theGoogleOnlyWordsAreGoneFromTheSources() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let roots = [apple.appending(path: "Taskforce"), apple.appending(path: "Packages/TaskforceKit/Sources")]
        let banned = [
            "supports Google sign-in only", "Google-only", "Google sign-in only", "Contact for account access", "googleOnly", "googleOnlyNotice",
            "unavailable in this Google", "Sign in with Google before deleting", "Google sign-in is unavailable in this build",
        ]
        var scanned = 0
        for root in roots {
            let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                scanned += 1
                for word in banned { #expect(!text.contains(word), "\(word) in \(url.lastPathComponent)") }
            }
        }
        #expect(scanned > 100)
    }
}

private struct NoStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}

/// 앱 밖에서 열린 주소 (OA 로그인 계약 5.1-8 · 11.2): `taskforce://auth/apple…`은 아무 데도 보내지 않는다
@MainActor
struct OpenedURLRoutingTests {
    @MainActor
    final class Routed {
        var google: [URL] = []
        var artifacts: [UUID] = []
        var connections: [URL] = []
    }

    func route(_ urls: [URL], googleHandles: Bool = false, launcherOpen: Bool = true) -> Routed {
        let routed = Routed()
        MacAppDelegate.routeOpenedURLs(urls,
            google: { routed.google.append($0); return googleHandles },
            artifact: { routed.artifacts.append($0); return launcherOpen },
            connection: { routed.connections.append($0) })
        return routed
    }

    @Test func anAppleCallbackOpenedFromOutsideDoesNothing() {
        for raw in [
            "taskforce://auth/apple?state=Abcdefghijklmnop_-0123456789&id_token=a.b.c&code=c1",
            "taskforce://auth/apple?error=user_cancelled_authorize",
            "taskforce://auth/apple", "TASKFORCE://AUTH/apple/?id_token=x", "taskforce://auth/apple?state=bad",
        ] {
            let routed = route([URL(string: raw)!])
            #expect(routed.connections.isEmpty, Comment(rawValue: raw))
            #expect(routed.artifacts.isEmpty && routed.google.isEmpty, Comment(rawValue: raw))
        }
    }

    @Test func otherAddressesStillGoWhereTheyWent() {
        let connection = URL(string: "taskforce://connections/notion?handoff=abc")!
        let routed = route([connection])
        #expect(routed.connections == [connection])
        let id = UUID()
        let draft = URL(string: "taskforce://artifacts/\(id.uuidString.lowercased())")!
        let draftRouted = route([draft])
        #expect(draftRouted.artifacts == [id])
        #expect(draftRouted.connections.isEmpty)
        // 런처가 없으면 초안 링크는 예전처럼 연결 콜백으로 떨어진다
        #expect(route([draft], launcherOpen: false).connections == [draft])
        // Google 콜백은 Google SDK가 가져간다
        let google = URL(string: "com.googleusercontent.apps.123-abc:/oauth2callback?code=x")!
        let googleRouted = route([google], googleHandles: true)
        #expect(googleRouted.google == [google] && googleRouted.connections.isEmpty)
    }

    @Test func aMixedBatchRoutesEachAddressOnItsOwn() {
        let apple = URL(string: "taskforce://auth/apple?state=Abcdefghijklmnop_-0123456789&id_token=a.b.c")!
        let connection = URL(string: "taskforce://connections/slack?handoff=1")!
        let routed = route([apple, connection, apple])
        #expect(routed.connections == [connection])
    }

    @Test func theAppleCallbackPredicateIsExact() {
        #expect(AppleSignInFlow.isAppleCallback(URL(string: "taskforce://auth/apple?x=1")!))
        #expect(AppleSignInFlow.isAppleCallback(URL(string: "taskforce://auth/apple/")!))
        #expect(!AppleSignInFlow.isAppleCallback(URL(string: "taskforce://auth/applepie")!))
        #expect(!AppleSignInFlow.isAppleCallback(URL(string: "taskforce://connections/apple")!))
        #expect(!AppleSignInFlow.isAppleCallback(URL(string: "https://auth/apple")!))
        #expect(!AppleSignInFlow.isAppleCallback(URL(string: "taskforce://auth/google")!))
    }
}
