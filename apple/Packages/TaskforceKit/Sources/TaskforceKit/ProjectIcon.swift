import Foundation

/// 프로젝트 아이콘 이름 (OA U2, DS ProjectIcon): 서버 풀 12종(`PROJECT_ICON_POOL`)과 풀 밖의 `folder`.
/// 새 프로젝트가 다음 안 쓴 것을 받는 규칙은 서버가 정한다 (D4c-1m). `ungrouped` · `done-today` 아이콘은 선택지가 아니라 고정이라 이 목록에 없다 (행 종류가 정한다).
/// 앱의 글리프는 `TFIcon`이 이 이름(Lucide)으로 그린다
public enum ProjectIconName: String, Sendable, Hashable, CaseIterable {
    case rocket
    case briefcase
    case flaskConical = "flask-conical"
    case palette
    case codeXml = "code-xml"
    case megaphone
    case bookOpen = "book-open"
    case building2 = "building-2"
    case leaf
    case compass
    case target
    case users
    /// 풀 밖의 이름 · 아직 모르는 값 (DS: "풀 밖 이름은 folder")
    case folder

    /// 서버 풀 (순서 그대로)
    public static let pool: [ProjectIconName] = [
        .rocket, .briefcase, .flaskConical, .palette, .codeXml, .megaphone, .bookOpen, .building2, .leaf, .compass, .target, .users,
    ]

    /// 모르는 이름 · 없는 값은 folder
    public init(raw: String?) {
        self = raw.flatMap(ProjectIconName.init(rawValue:)) ?? .folder
    }

    public var raw: String { rawValue }
}
