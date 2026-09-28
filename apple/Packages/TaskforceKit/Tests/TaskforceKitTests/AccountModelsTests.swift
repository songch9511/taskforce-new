import Foundation
import Testing
@testable import TaskforceKit

struct AccountModelsTests {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TaskforceJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func profileWithConsent() throws {
        let profile = try decode(Profile.self, #"{"display_name":"김도윤","aliases":["Doyun"],"emails":["a@b.co"],"ai_consent_at":"2026-09-27T01:02:03.123+00:00"}"#)
        #expect(profile.displayName == "김도윤")
        #expect(profile.hasAIConsent)
        #expect(profile.reportsConsent)
    }

    @Test func profileWithoutConsentField() throws {
        let older = try decode(Profile.self, #"{"display_name":null,"aliases":[],"emails":[]}"#)
        #expect(!older.hasAIConsent)
        #expect(!older.reportsConsent)
        let notYet = try decode(Profile.self, #"{"display_name":null,"aliases":[],"emails":[],"ai_consent_at":null}"#)
        #expect(!notYet.hasAIConsent)
        #expect(notYet.reportsConsent)
    }

    @Test func profileEncodeLeavesConsentToConsentEndpoint() throws {
        let profile = Profile(displayName: nil, aliases: ["A"], emails: [], aiConsentAt: Date(), reportsConsent: true)
        let data = try TaskforceJSON.encoder().encode(profile)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["display_name", "aliases", "emails"])
        #expect(object["display_name"] is NSNull)
    }

    @Test func consentPromptOnlyWhenMissingAndConnected() throws {
        let missing = try decode(Profile.self, #"{"display_name":null,"aliases":[],"emails":[],"ai_consent_at":null}"#)
        let given = try decode(Profile.self, #"{"display_name":null,"aliases":[],"emails":[],"ai_consent_at":"2026-09-27T01:02:03Z"}"#)
        let olderServer = try decode(Profile.self, #"{"display_name":null,"aliases":[],"emails":[]}"#)
        #expect(AIConsentRule.shouldPrompt(profile: missing, hasConnections: true))
        #expect(!AIConsentRule.shouldPrompt(profile: missing, hasConnections: false))
        #expect(!AIConsentRule.shouldPrompt(profile: given, hasConnections: true))
        #expect(!AIConsentRule.shouldPrompt(profile: olderServer, hasConnections: true))
        #expect(!AIConsentRule.shouldPrompt(profile: nil, hasConnections: true))
        #expect(AIConsentRule.isMissing(missing) && !AIConsentRule.isMissing(given))
    }

    @Test func editedProfileFollowsServerLimits() {
        let current = Profile(displayName: "Old", aliases: [], emails: ["me@x.co"], aiConsentAt: nil, reportsConsent: true)
        let edited = Profile.edited(name: "  김도윤 ", aliases: ["Doyun", " ", "Doyun", "김도윤", String(repeating: "a", count: 60)], keeping: current)
        #expect(edited.displayName == "김도윤")
        #expect(edited.aliases == ["Doyun", String(repeating: "a", count: 50)])
        #expect(edited.emails == ["me@x.co"])
        #expect(Profile.edited(name: "   ", aliases: [], keeping: current).displayName == nil)
        #expect(Profile.aliases(fromList: "Doyun, 도윤\n DY ,") == ["Doyun", "도윤", "DY"])
    }

    @Test func askResponseIsTolerant() throws {
        let response = try decode(AskResponse.self, """
        {"answer":"금요일까지예요.","unknown":false,"citations":[
          {"action_id":null,"source_id":"22222222-2222-4222-8222-222222222222","source_title":"주간 회의","source_kind":"meeting",
           "occurred_at":"2026-09-24T02:00:00+00:00","external_url":"https://www.notion.so/abc","quote":"자료 금요일까지"},
          {"source_id":"not-a-uuid","quote":"x"},
          {"source_id":"22222222-2222-4222-8222-222222222222","source_kind":"calendar","quote":"새 종류","external_url":"not a url"}
        ]}
        """)
        #expect(response.answer == "금요일까지예요.")
        #expect(response.citations.count == 2)
        #expect(response.citations[0].service == .notion)
        #expect(response.citations[0].actionID == nil)
        #expect(response.citations[1].sourceKind == .note)
        #expect(EvidenceLine(response.citations[0]).sourceTitle == "주간 회의")
    }

    @Test func askUnknownAnswer() throws {
        let response = try decode(AskResponse.self, #"{"answer":"모르겠어요.","unknown":true,"citations":[]}"#)
        #expect(response.unknown && response.citations.isEmpty)
    }

    @Test func createSourceEncodesOnlyGivenFields() throws {
        let body = try JSONSerialization.jsonObject(with: TaskforceJSON.encoder().encode(CreateSourceRequest(kind: .note, text: "본문", title: "제목")))
        #expect(body as? NSDictionary == ["kind": "note", "text": "본문", "title": "제목"] as NSDictionary)
    }
}
