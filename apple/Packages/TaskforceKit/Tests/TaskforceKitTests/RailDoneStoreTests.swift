import Foundation
import Testing
@testable import TaskforceKit

/// 사전으로 UserDefaults를 흉내 낸다: 시험이 실제 설정 도메인을 만들지 않는다
final class FakeRailDefaults: RailDoneDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    var keys: [String] { lock.withLock { values.keys.sorted() } }
}

/// 레일의 "열 때까지 남는 끝남" 저장 (계약 23장: 끝난 링은 사용자가 열어 볼 때까지 레일에 남고, 마지막으로 연 기록은 이 Mac에 저장해 다시 켠 뒤에도 남는다).
/// 저장하는 것은 id · 본 시각뿐이다 (제목 · 글 · 경로 0), 이 Mac에만 있다
struct RailDoneStoreTests {
    typealias Fx = SessionFx
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theInMemoryStoreRoundTripsAndStartsEmpty() {
        let store = InMemoryRailDoneStore()
        #expect(store.load() == RailDoneMarks())
        let marks = RailDoneMarks(sessions: [Fx.id(1): t0], issues: [Fx.issue(1): t0.addingTimeInterval(5)])
        store.save(marks)
        #expect(store.load() == marks)
    }

    @Test func theUserDefaultsStoreSavesJSONUnderOneKeyAndReadsItBack() throws {
        let defaults = FakeRailDefaults()
        let marks = RailDoneMarks(sessions: [Fx.id(1): t0, Fx.id(2): t0.addingTimeInterval(7)], issues: [Fx.issue(3): t0.addingTimeInterval(9)])
        UserDefaultsRailDoneStore(defaults: defaults).save(marks)
        #expect(defaults.keys == [UserDefaultsRailDoneStore.key], "한 칸에 JSON 하나")
        // 다시 켠 것처럼 새 저장소로 읽는다
        #expect(UserDefaultsRailDoneStore(defaults: defaults).load() == marks)
        // 저장된 글에는 id · 시각뿐이다
        let data = try #require(defaults.object(forKey: UserDefaultsRailDoneStore.key) as? Data)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(Fx.id(1).uuidString.lowercased()))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["sessions", "issues"], "다른 칸 0")
    }

    @Test func unreadableOrForeignDataGivesEmptyMarksAndNeverCrashes() {
        let defaults = FakeRailDefaults()
        let store = UserDefaultsRailDoneStore(defaults: defaults)
        for bad: Any in [Data("not json".utf8), Data("[1,2,3]".utf8), Data(), "a string", 42, Data(#"{"sessions":{"not-a-uuid":1},"issues":7}"#.utf8)] {
            defaults.set(bad, forKey: UserDefaultsRailDoneStore.key)
            #expect(store.load() == RailDoneMarks(), "\(type(of: bad))")
        }
        // 모르는 id 키 하나가 섞여도 읽을 수 있는 것은 읽는다
        let mixed = #"{"sessions":{"not-a-uuid":1,"\#(Fx.id(1).uuidString.lowercased())":100},"issues":{}}"#
        defaults.set(Data(mixed.utf8), forKey: UserDefaultsRailDoneStore.key)
        #expect(store.load() == RailDoneMarks(sessions: [Fx.id(1): Date(timeIntervalSince1970: 100)]))
    }

    @Test func eachBucketKeepsTheNewestMarksUpToTheCapWhenSaved() {
        let defaults = FakeRailDefaults()
        let store = UserDefaultsRailDoneStore(defaults: defaults)
        var sessions: [UUID: Date] = [:]
        for n in 0..<(RailDoneMarks.limit + 30) { sessions[Fx.id(n + 1)] = t0.addingTimeInterval(Double(n)) }
        store.save(RailDoneMarks(sessions: sessions, issues: [:]))
        let loaded = store.load()
        #expect(loaded.sessions.count == RailDoneMarks.limit, "저장소가 커지지 않는다")
        #expect(loaded.sessions.values.min() == t0.addingTimeInterval(30), "넘치면 오래된 것부터 버린다")
    }

    @Test func updateChangesOnlyWhatTheClosureTouches() {
        let store = InMemoryRailDoneStore()
        store.save(RailDoneMarks(sessions: [Fx.id(1): t0], issues: [Fx.issue(1): t0]))
        store.update { $0.sessions[Fx.id(2)] = t0.addingTimeInterval(1) }
        #expect(store.load().sessions.keys.sorted { $0.uuidString < $1.uuidString } == [Fx.id(1), Fx.id(2)])
        #expect(store.load().issues == [Fx.issue(1): t0], "다른 칸은 그대로")
    }

    /// 표시의 주인 계정 (보안 P3-1): 표시와 같은 JSON에 소문자 UUID 하나로 적는다. 주인을 모르면(없거나 읽을 수 없으면) nil
    @Test func theOwnerAccountIsSavedWithTheMarksAndReadBackAfterARelaunch() throws {
        let owner = UUID(uuidString: "0B0B0B0B-0000-4000-8000-000000000002")!
        let defaults = FakeRailDefaults()
        let store = UserDefaultsRailDoneStore(defaults: defaults)
        #expect(store.load().owner == nil)
        store.save(RailDoneMarks(sessions: [Fx.id(1): t0], issues: [:], owner: owner))
        #expect(UserDefaultsRailDoneStore(defaults: defaults).load().owner == owner)
        let data = try #require(defaults.object(forKey: UserDefaultsRailDoneStore.key) as? Data)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["sessions", "issues", "owner"] && object["owner"] as? String == owner.uuidString.lowercased())
        // 한 칸만 고치는 `update`는 주인을 지우지 않는다
        store.update { $0.sessions[Fx.id(2)] = t0 }
        #expect(store.load().owner == owner)
        store.setOwner(nil)
        #expect(store.load().owner == nil && store.load().sessions.count == 2)
        // 읽을 수 없는 주인은 모른다 (표시는 읽는다)
        for bad in [#""nope""#, "7", "null", #""""#] {
            let json = #"{"sessions":{"\#(Fx.id(1).uuidString.lowercased())":100},"issues":{},"owner":\#(bad)}"#
            defaults.set(Data(json.utf8), forKey: UserDefaultsRailDoneStore.key)
            #expect(store.load().owner == nil && store.load().sessions.count == 1, Comment(rawValue: bad))
        }
    }

    @Test func clearRemovesTheOwnerToo() {
        let store = InMemoryRailDoneStore()
        store.save(RailDoneMarks(sessions: [Fx.id(1): t0], issues: [:], owner: UUID()))
        store.clear()
        #expect(store.load() == RailDoneMarks() && store.load().owner == nil)
    }

    @Test func clearRemovesEverythingSoNothingOfAnOldAccountStays() {
        let defaults = FakeRailDefaults()
        let store = UserDefaultsRailDoneStore(defaults: defaults)
        store.save(RailDoneMarks(sessions: [Fx.id(1): t0], issues: [Fx.issue(1): t0]))
        store.clear()
        #expect(store.load() == RailDoneMarks())
        #expect(defaults.object(forKey: UserDefaultsRailDoneStore.key) == nil, "남는 저장본이 없다")
    }

    @Test func theMarksPrintNoID() {
        let marks = RailDoneMarks(sessions: [Fx.id(1): t0], issues: [Fx.issue(1): t0])
        for value in [String(describing: marks), String(reflecting: marks)] {
            #expect(!value.contains(Fx.id(1).uuidString) && !value.contains(Fx.issue(1).uuidString), "\(value)")
        }
    }
}
