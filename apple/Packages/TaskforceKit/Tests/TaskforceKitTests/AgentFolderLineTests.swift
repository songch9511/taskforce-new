import Foundation
import Testing
@testable import TaskforceKit

/// 대화 머리의 작업 폴더 줄 (사용자 결정 2026-10-21): 폴더 이름 + 툴팁의 경로 (`~` · 가운데 줄임, Settings › Your agents의 Folders와 같은 `AgentSettingsPath` 규칙).
/// 경로는 이 Mac에만 있다 — 보이는 글을 만들 뿐이다
struct AgentWorkspaceFolderLineTests {
    let home = "/Users/daniel"
    let limit = AgentSettingsPath.maxLength

    private func make(_ path: String, homes: [String]? = nil) -> AgentWorkspaceFolderLine? {
        AgentWorkspaceFolderLine(path: path, homes: homes ?? [home])
    }

    /// Show in Finder는 폴더가 지금 있을 때만 켜진다 (사용자 승인 2026-10-22): 줄이 그 사실을 실어 나른다 (기본은 있음)
    @Test func theLineCarriesWhetherTheFolderStillExistsForShowInFinder() throws {
        #expect(try #require(make("/Users/daniel/Documents/client-a")).exists, "기본은 있음")
        let gone = try #require(AgentWorkspaceFolderLine(path: "/Users/daniel/Documents/client-a", homes: [home], exists: false))
        #expect(!gone.exists && gone.name == "client-a" && gone.tooltip == "~/Documents/client-a", "없어도 이름 · 경로는 그대로 보인다")
    }

    @Test func theHeaderShowsTheFolderNameAndTheTooltipShowsTheFullPathWithTildeForHome() throws {
        let shown = try #require(make("/Users/daniel/Documents/client-a"))
        #expect(shown.name == "client-a")
        #expect(shown.tooltip == "~/Documents/client-a")
    }

    @Test func aFolderOutsideHomeKeepsItsAbsolutePathInTheTooltip() throws {
        let shown = try #require(make("/Volumes/Work Drive/acme"))
        #expect(shown.name == "acme" && shown.tooltip == "/Volumes/Work Drive/acme")
    }

    @Test func aSiblingOfHomeWithTheSamePrefixIsNotHome() throws {
        let shown = try #require(make("/Users/daniel2/Documents/x"))
        #expect(shown.tooltip == "/Users/daniel2/Documents/x", "접두 글자가 같다고 `~`로 줄이지 않는다")
    }

    @Test func theRealpathOfHomeIsAbbreviatedToo() throws {
        let shown = try #require(make("/private/Users/daniel/Documents/client-a", homes: ["/private/Users/daniel", home]))
        #expect(shown.tooltip == "~/Documents/client-a")
    }

    @Test func aTrailingOrDoubledSlashDoesNotEmptyTheNameOrBreakTheTilde() throws {
        let trailing = try #require(make("/Users/daniel/Documents/client-a/"))
        #expect(trailing.name == "client-a" && trailing.tooltip == "~/Documents/client-a")
        let doubled = try #require(make("/Users/daniel//Documents//client-a"))
        #expect(doubled.name == "client-a" && doubled.tooltip == "~/Documents/client-a")
    }

    @Test func homeItselfIsTildeAndAnEmptyOrRootPathHasNoLine() throws {
        let shown = try #require(make(home))
        #expect(shown.name == "~" && shown.tooltip == "~")
        #expect(make("") == nil)
        #expect(make("/") == nil, "이름이 없는 뿌리는 줄이 아니다")
    }

    @Test func anEmptyOrRootHomeNeverAbbreviatesAnything() throws {
        #expect(try #require(make("/Users/daniel/x", homes: [""])).tooltip == "/Users/daniel/x")
        #expect(try #require(make("/Users/daniel/x", homes: ["/"])).tooltip == "/Users/daniel/x")
        #expect(try #require(make("/Users/daniel/x", homes: [])).tooltip == "/Users/daniel/x")
    }

    @Test func aPathThatFitsIsNeverCut() throws {
        let path = "/Users/daniel/Documents/" + String(repeating: "a", count: 60)
        let shown = try #require(make(path))
        #expect(shown.tooltip == "~/Documents/" + String(repeating: "a", count: 60) && shown.tooltip.count <= limit)
    }

    @Test func aLongPathIsCutInTheMiddleSoBothTheStartAndTheFolderNameStayVisible() throws {
        let path = "/Users/daniel/Documents/clients/acme-corporation/websites/redesign-2026/frontend/storefront/packages/checkout/payment-methods/storefront-app"
        let shown = try #require(make(path))
        #expect(shown.name == "storefront-app", "머리의 이름은 줄이지 않는다: 보이는 폭이 모자랄 때만 화면이 가운데를 줄인다")
        #expect(shown.tooltip.count == limit)
        #expect(shown.tooltip.hasPrefix("~/Documents/clients/") && shown.tooltip.hasSuffix("/payment-methods/storefront-app"))
        #expect(shown.tooltip.filter { $0 == "…" }.count == 1, "가운데 한 곳만")
    }

    @Test func aLongPathOutsideHomeIsAlsoCutInTheMiddle() throws {
        let path = "/Volumes/" + String(repeating: "Work-Drive-", count: 12) + "/acme/storefront"
        let shown = try #require(make(path))
        #expect(shown.tooltip.count == limit && shown.tooltip.hasPrefix("/Volumes/") && shown.tooltip.hasSuffix("/acme/storefront") && shown.name == "storefront")
    }

    @Test func aFolderNameLongerThanTheLimitKeepsItsWholeNameInTheHeaderValue() throws {
        let name = String(repeating: "x", count: 200)
        let shown = try #require(make("/Users/daniel/Documents/" + name))
        #expect(shown.name == name && shown.tooltip.count == limit)
    }

    @Test func koreanAndEmojiCountAsCharactersNotBytesWhenItCuts() throws {
        let path = "/Users/daniel/Documents/" + String(repeating: "고객사-", count: 30) + "/웹사이트 🚀"
        let shown = try #require(make(path))
        #expect(shown.name == "웹사이트 🚀" && shown.tooltip.count == limit && shown.tooltip.hasSuffix("/웹사이트 🚀"))
    }
}
