import Foundation

/// All work 고정의 저장 (계정별). `actions`에 고정 열이 없고 서버 API도 없어서 이 Mac에만 둔다:
/// 앱 설정과 다른 전용 UserDefaults suite(`suiteName`)에 계정마다 할 일 id만 적는다 (제목 · 내용은 적지 않는다).
/// `defaults`가 nil이면 메모리에만 둔다 (견본 · 테스트: 디스크에 쓰지 않는다).
@MainActor
public final class WorkPinStore {
    private let defaults: UserDefaults?
    private var memory: [UUID: WorkPins] = [:]

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    /// 전용 suite 이름 (앱 번들 id 뒤에 붙인다: 앱의 기본 설정 파일과 섞이지 않는다)
    public static func suiteName(bundleID: String) -> String {
        "\(bundleID).work-pins"
    }

    static func key(_ account: UUID) -> String {
        "pins.\(account.uuidString.lowercased())"
    }

    public func load(account: UUID) -> WorkPins {
        guard let defaults else { return memory[account] ?? WorkPins() }
        let ids = (defaults.stringArray(forKey: Self.key(account)) ?? []).compactMap(UUID.init(uuidString:))
        return WorkPins(ids)
    }

    public func save(_ pins: WorkPins, account: UUID) {
        guard let defaults else {
            memory[account] = pins
            return
        }
        if pins.ids.isEmpty {
            defaults.removeObject(forKey: Self.key(account))
        } else {
            defaults.set(pins.ids.map { $0.uuidString.lowercased() }, forKey: Self.key(account))
        }
    }
}
