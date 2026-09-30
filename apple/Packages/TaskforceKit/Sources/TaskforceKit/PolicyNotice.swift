import Foundation

// 개인정보 처리방침 변경 안내 (처리방침 17장: 바뀌면 앱과 페이지에 알린다).
// 누구에게 보일지(가입 시각 · 시행 예정 판)는 서버가 정한다 (GET /api/v1/legal `notice`). 앱은 이 계정이 그 판을 이미 열거나 닫았는지만 본다.

/// GET /api/v1/legal (contract.ts `legalResponseSchema`)
public struct LegalResponse: Decodable, Sendable, Hashable {
    public let privacy: PrivacyPolicyStatus
}

public struct PrivacyPolicyStatus: Decodable, Sendable, Hashable {
    public let current: PolicyVersion
    public let upcoming: PolicyVersion?
    /// 이 계정에 보일 안내. 없으면 nil
    public let notice: PolicyNotice?
}

/// contract.ts `policyVersionSchema`
public struct PolicyVersion: Decodable, Sendable, Hashable {
    public let version: String
    public let effectiveDate: LocalDate
    public let url: PolicyLinks

    enum CodingKeys: String, CodingKey {
        case version, url
        case effectiveDate = "effective_date"
    }
}

/// 처리방침 페이지 (한국어 · 영어)
public struct PolicyLinks: Decodable, Sendable, Hashable {
    public let ko: URL
    public let en: URL

    public init(ko: URL, en: URL) {
        self.ko = ko
        self.en = en
    }

    /// 기기의 첫 언어가 한국어면 한국어 페이지, 아니면 영어 페이지
    public func url(preferredLanguages: [String] = Locale.preferredLanguages) -> URL {
        let first = preferredLanguages.first.map { Locale.Language(identifier: $0).languageCode }
        return first == .korean ? ko : en
    }
}

/// contract.ts `policyNoticeSchema`
public struct PolicyNotice: Decodable, Sendable, Hashable {
    public enum Kind: String, Decodable, Sendable {
        /// 시행된 판 (그 전에 가입한 계정)
        case updated
        /// 시행 예정 판 (시행 7일 · 30일 전부터)
        case upcoming
    }

    public let kind: Kind
    public let version: String
    public let effectiveDate: LocalDate
    public let url: PolicyLinks

    enum CodingKeys: String, CodingKey {
        case kind, version, url
        case effectiveDate = "effective_date"
    }

    public init(kind: Kind, version: String, effectiveDate: LocalDate, url: PolicyLinks) {
        self.kind = kind
        self.version = version
        self.effectiveDate = effectiveDate
        self.url = url
    }

    /// 한 줄 문구: "Privacy Policy updated" · "Privacy Policy changes Oct 7"
    public func title(today: LocalDate = DueDateFormat.today()) -> String {
        switch kind {
        case .updated: "Privacy Policy updated"
        case .upcoming: "Privacy Policy changes \(DueText.date(effectiveDate, today: today))"
        }
    }
}

/// 이 계정이 열거나 닫은 안내의 판 (이 기기에만, 계정마다). 서버에는 남기지 않는다: 처리방침(베타 1.1)이 적지 않은 이용 기록이 된다.
/// 판 이름으로 적어서, 미리 본 시행 예정 판이 시행돼도 같은 판이면 다시 보이지 않는다.
public enum PolicyNoticeSeen {
    static func key(_ userID: UUID) -> String {
        "policyNoticeSeen.\(userID.uuidString.lowercased())"
    }

    public static func versions(for userID: UUID, in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key(userID)) ?? [])
    }

    public static func mark(_ version: String, for userID: UUID, in defaults: UserDefaults = .standard) {
        let seen = versions(for: userID, in: defaults).union([version])
        defaults.set(seen.sorted(), forKey: key(userID))
    }

    /// 보일 안내: 서버가 준 안내 중 이 계정이 아직 열거나 닫지 않은 판
    public static func pending(_ notice: PolicyNotice?, for userID: UUID, in defaults: UserDefaults = .standard) -> PolicyNotice? {
        guard let notice, !versions(for: userID, in: defaults).contains(notice.version) else { return nil }
        return notice
    }
}
