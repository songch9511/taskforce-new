import Foundation

/// 근거가 어디서 왔나. 화면은 서비스 이름을 글자로 쓰지 않고 로고로 보여 준다 (docs/BRAND.md "UI 문구").
/// 연동 원문은 원본 링크(`external_url`)의 주소로 서비스를 알아내고, 직접 넣은 원문은 종류(`kind`)로 보여 준다.
public enum SourceService: Hashable, Sendable {
    case notion
    case slack
    case gmail
    case googleMeet
    /// 연동이 아닌 원문 (붙여 넣기 · 메모). 로고 대신 종류 기호를 쓴다.
    case manual(SourceKind)

    public static func infer(externalURL: URL?, kind: SourceKind) -> SourceService {
        guard let host = externalURL?.host?.lowercased() else { return .manual(kind) }
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if matches("notion.so") || matches("notion.site") || matches("notion.com") { return .notion }
        if matches("slack.com") { return .slack }
        if matches("mail.google.com") { return .gmail }
        // Meet 전사는 Google Docs 문서로 남는다. 회의(meeting) 원문일 때만 Meet으로 본다.
        if matches("meet.google.com") { return .googleMeet }
        if matches("docs.google.com") || matches("calendar.google.com") {
            return kind == .meeting ? .googleMeet : .manual(kind)
        }
        return .manual(kind)
    }

    /// 접근성 이름 (화면에 글자로 쓰지 않는다)
    public var accessibilityName: String {
        switch self {
        case .notion: "Notion"
        case .slack: "Slack"
        case .gmail: "Gmail"
        case .googleMeet: "Google Meet"
        case .manual(let kind):
            switch kind {
            case .meeting: "Meeting notes"
            case .message: "Message"
            case .email: "Email"
            case .doc: "Document"
            case .note: "Note"
            case .task: "Task"
            case .execution: "Execution record"
            }
        }
    }
}

/// Source stack 규칙 (Figma 11:214 · 11:949). 순수 함수라 테스트로 고정한다.
public enum SourceStackLayout {
    public struct Result: Equatable, Sendable {
        /// 그릴 아이콘 (왼쪽이 위, 처음 들어온 출처가 맨 왼쪽)
        public let icons: [SourceService]
        /// "+N" (0이면 그리지 않음)
        public let more: Int

        public init(icons: [SourceService], more: Int) {
            self.icons = icons
            self.more = more
        }
    }

    /// Sources 묶음 머리 (20pt): 같은 서비스는 한 번만. 4개 이상이면 3개 + "+N".
    public static func medium(_ services: [SourceService]) -> Result {
        let unique = uniqued(services)
        guard unique.count >= 4 else { return Result(icons: unique, more: 0) }
        return Result(icons: Array(unique.prefix(3)), more: unique.count - 3)
    }

    /// 근거 줄 끝의 작은 겹침 (14pt): 맨 앞에 보인 출처는 뺀 나머지 출처 수가 N.
    /// 아이콘은 서비스마다 한 번, 많아야 2개. 아이콘 수 + "+N" = 나머지 출처 수 (예: 5곳 = 아이콘 2 + "+3").
    public static func small(others: [SourceService]) -> Result {
        let icons = Array(uniqued(others).prefix(2))
        return Result(icons: icons, more: others.count - icons.count)
    }

    private static func uniqued(_ services: [SourceService]) -> [SourceService] {
        var seen = Set<SourceService>()
        return services.filter { seen.insert($0).inserted }
    }
}
