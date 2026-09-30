import Foundation
import Testing
@testable import TaskforceKit

/// 처리방침 변경 안내: GET /api/v1/legal 해석 · 문구 · 언어별 주소 · 계정별로 본 판 · 런처 줄
struct PolicyNoticeTests {
    static let legalJSON = """
    {"privacy":{
      "current":{"version":"beta-1.1","effective_date":"2026-09-30","url":{"ko":"https://www.taskforcelabs.dev/ko/privacy","en":"https://www.taskforcelabs.dev/en/privacy"}},
      "upcoming":{"version":"beta-1.2","effective_date":"2026-10-07","url":{"ko":"https://www.taskforcelabs.dev/ko/privacy","en":"https://www.taskforcelabs.dev/en/privacy"}},
      "notice":{"kind":"upcoming","version":"beta-1.2","effective_date":"2026-10-07","url":{"ko":"https://www.taskforcelabs.dev/ko/privacy","en":"https://www.taskforcelabs.dev/en/privacy"}}
    }}
    """

    static let links = PolicyLinks(
        ko: URL(string: "https://www.taskforcelabs.dev/ko/privacy")!,
        en: URL(string: "https://www.taskforcelabs.dev/en/privacy")!
    )
    static let updated = PolicyNotice(kind: .updated, version: "beta-1.1", effectiveDate: LocalDate("2026-09-30")!, url: links)

    @Test func decodesLegalResponse() throws {
        let response = try TaskforceJSON.decoder().decode(LegalResponse.self, from: Data(Self.legalJSON.utf8))
        #expect(response.privacy.current.version == "beta-1.1")
        #expect(response.privacy.current.effectiveDate == LocalDate("2026-09-30"))
        #expect(response.privacy.upcoming?.version == "beta-1.2")
        let notice = try #require(response.privacy.notice)
        #expect(notice.kind == .upcoming)
        #expect(notice.effectiveDate == LocalDate("2026-10-07"))
        #expect(notice.url == Self.links)
    }

    @Test func decodesNoNotice() throws {
        let json = """
        {"privacy":{"current":{"version":"beta-1.1","effective_date":"2026-09-30","url":{"ko":"https://a.test/ko","en":"https://a.test/en"}},"upcoming":null,"notice":null}}
        """
        let response = try TaskforceJSON.decoder().decode(LegalResponse.self, from: Data(json.utf8))
        #expect(response.privacy.upcoming == nil)
        #expect(response.privacy.notice == nil)
    }

    @Test func titleIsTerse() {
        let today = LocalDate("2026-09-30")!
        #expect(Self.updated.title(today: today) == "Privacy Policy updated")
        let upcoming = PolicyNotice(kind: .upcoming, version: "beta-1.2", effectiveDate: LocalDate("2026-10-07")!, url: Self.links)
        #expect(upcoming.title(today: today) == "Privacy Policy changes Oct 7")
        #expect(upcoming.title(today: LocalDate("2025-12-30")!) == "Privacy Policy changes Oct 7, 2026")
    }

    @Test func koreanDeviceOpensKoreanPage() {
        #expect(Self.links.url(preferredLanguages: ["ko-KR", "en-US"]) == Self.links.ko)
        #expect(Self.links.url(preferredLanguages: ["ko"]) == Self.links.ko)
        #expect(Self.links.url(preferredLanguages: ["en-KR", "ko-KR"]) == Self.links.en)
        #expect(Self.links.url(preferredLanguages: ["ja-JP"]) == Self.links.en)
        #expect(Self.links.url(preferredLanguages: []) == Self.links.en)
    }

    @Test func seenVersionIsPerAccount() throws {
        let defaults = try #require(UserDefaults(suiteName: "policy-\(UUID().uuidString)"))
        let me = UUID()
        let other = UUID()
        #expect(PolicyNoticeSeen.pending(Self.updated, for: me, in: defaults) == Self.updated)
        PolicyNoticeSeen.mark("beta-1.1", for: me, in: defaults)
        #expect(PolicyNoticeSeen.pending(Self.updated, for: me, in: defaults) == nil)
        // 같은 기기의 다른 계정은 아직 보지 않았다
        #expect(PolicyNoticeSeen.pending(Self.updated, for: other, in: defaults) == Self.updated)
        // 새 판은 다시 보인다
        let next = PolicyNotice(kind: .updated, version: "beta-1.2", effectiveDate: LocalDate("2026-10-07")!, url: Self.links)
        #expect(PolicyNoticeSeen.pending(next, for: me, in: defaults) == next)
        PolicyNoticeSeen.mark("beta-1.2", for: me, in: defaults)
        PolicyNoticeSeen.mark("beta-1.2", for: me, in: defaults)
        #expect(PolicyNoticeSeen.versions(for: me, in: defaults) == ["beta-1.1", "beta-1.2"])
        #expect(PolicyNoticeSeen.pending(nil, for: me, in: defaults) == nil)
    }

    /// 미리 본 시행 예정 판은 시행된 뒤("updated")에도 같은 판이라 다시 보이지 않는다
    @Test func upcomingSeenCoversSameVersionOnceEffective() throws {
        let defaults = try #require(UserDefaults(suiteName: "policy-\(UUID().uuidString)"))
        let me = UUID()
        PolicyNoticeSeen.mark("beta-1.2", for: me, in: defaults)
        let effective = PolicyNotice(kind: .updated, version: "beta-1.2", effectiveDate: LocalDate("2026-10-07")!, url: Self.links)
        #expect(PolicyNoticeSeen.pending(effective, for: me, in: defaults) == nil)
    }

    @Test func legalIsAuthenticatedGet() async throws {
        let host = "l\(UUID().uuidString.lowercased().prefix(8)).test"
        StubProtocol.register(host: host, reply: .init(status: 200, body: Self.legalJSON))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration)) { "token-123" }
        let response = try await api.legal()
        #expect(response.privacy.notice?.version == "beta-1.2")
        let request = try #require(StubProtocol.requests(host: host).last)
        #expect(request.method == "GET")
        #expect(request.url.path == "/api/v1/legal")
        #expect(request.headers["Authorization"] == "Bearer token-123")
    }

    @Test func launcherShowsNoticeOnTopOfEmptyListOnly() throws {
        let now = try TaskforceJSON.decoder().decode(NowResponse.self, from: Data(Fixtures.nowWithWeeklyCheck.utf8))
        let sections = LauncherContent.sections(for: .empty, now: now, signedIn: true, policyNotice: Self.updated)
        #expect(sections.first?.items == [.policyNotice(Self.updated)])
        #expect(sections.map(\.title) == [nil, "Review", "In Progress", "To Do", "Commands"])
        // 동의 줄 아래
        let both = LauncherContent.sections(for: .empty, now: now, signedIn: true, needsConsent: true, policyNotice: Self.updated)
        #expect(both.first?.items == [.allowAI, .policyNotice(Self.updated)])
        // 찾는 중 · 로그아웃이면 보이지 않는다
        let query = LauncherContent.sections(for: .query("자료"), now: now, signedIn: true, policyNotice: Self.updated)
        #expect(!query.flatMap(\.items).contains(.policyNotice(Self.updated)))
        let signedOut = LauncherContent.sections(for: .empty, now: now, signedIn: false, policyNotice: Self.updated)
        #expect(!signedOut.flatMap(\.items).contains(.policyNotice(Self.updated)))
        #expect(LauncherItem.policyNotice(Self.updated).action == nil)
        #expect(LauncherItem.policyNotice(Self.updated).group == nil)
    }
}
