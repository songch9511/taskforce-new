import Foundation

/// All work 고정의 저장 (계정별). `actions`에 고정 열이 없고 서버 API도 없어서 이 Mac에만 둔다:
/// 앱 설정과 다른 전용 UserDefaults suite(`suiteName`)에 계정마다 할 일 id만 적는다 (제목 · 내용은 적지 않는다).
/// 지우기는 이 기기 저장본(`SavedNowStore`)과 같다: 계정이 떠나면(`SessionStore.onSignedOut`) 모두 지우고(`removeAll`),
/// 앱을 열 때 지금 계정 것만 남긴다(`prune(keeping:)`, 앱이 돌지 않는 동안 떠난 계정).
/// `defaults`가 nil이면 메모리에만 둔다 (견본 · 테스트 · 번들 id를 모를 때: 디스크에 쓰지 않는다).
@MainActor
public final class WorkPinStore {
    private let storage: WorkPinStorage

    public convenience init(defaults: UserDefaults?) {
        self.init(storage: defaults.map(DefaultsPinStorage.init) ?? MemoryPinStorage())
    }

    /// 테스트: 디스크 대신 메모리 저장을 넘겨 "앱을 다시 연 것"을 흉내 낸다 (`~/Library/Preferences`에 파일을 남기지 않는다)
    init(storage: WorkPinStorage) {
        self.storage = storage
    }

    /// 전용 suite 이름 (앱 번들 id 뒤에 붙인다: 앱의 기본 설정 파일과 섞이지 않는다)
    public static func suiteName(bundleID: String) -> String {
        "\(bundleID).work-pins"
    }

    static let keyPrefix = "pins."

    static func key(_ account: UUID) -> String {
        "\(keyPrefix)\(account.uuidString.lowercased())"
    }

    public func load(account: UUID) -> WorkPins {
        WorkPins((storage.strings(forKey: Self.key(account)) ?? []).compactMap(UUID.init(uuidString:)))
    }

    public func save(_ pins: WorkPins, account: UUID) {
        storage.set(pins.ids.isEmpty ? nil : pins.ids.map { $0.uuidString.lowercased() }, forKey: Self.key(account))
    }

    /// 모든 계정의 고정을 지운다 (계정이 떠날 때: 다른 계정의 고정이 이 기기에 남지 않게)
    public func removeAll() {
        for key in storage.keys where key.hasPrefix(Self.keyPrefix) {
            storage.set(nil, forKey: key)
        }
    }

    /// 그 계정 말고 다른 계정의 고정을 지운다 (앱을 열 때). 로그아웃이면(nil) 모두
    public func prune(keeping account: UUID?) {
        let keep = account.map(Self.key)
        for key in storage.keys where key.hasPrefix(Self.keyPrefix) && key != keep {
            storage.set(nil, forKey: key)
        }
    }
}

/// 고정을 적는 곳 (UserDefaults suite · 메모리)
@MainActor
protocol WorkPinStorage: AnyObject {
    func strings(forKey key: String) -> [String]?
    /// nil이면 지운다
    func set(_ value: [String]?, forKey key: String)
    var keys: [String] { get }
}

@MainActor
final class MemoryPinStorage: WorkPinStorage {
    private(set) var values: [String: [String]] = [:]

    func strings(forKey key: String) -> [String]? { values[key] }

    func set(_ value: [String]?, forKey key: String) { values[key] = value }

    var keys: [String] { Array(values.keys) }
}

@MainActor
final class DefaultsPinStorage: WorkPinStorage {
    private let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    func strings(forKey key: String) -> [String]? { defaults.stringArray(forKey: key) }

    func set(_ value: [String]?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// 전역 · 인자 영역의 키도 섞여 오지만 `pins.` 앞머리로 거른다
    var keys: [String] { Array(defaults.dictionaryRepresentation().keys) }
}
