import SwiftUI
import TaskforceKit

/// 앱 아이콘 (0.2.0 디자인 시스템 Iconography): Lucide 1.48.0 글리프, 웹 앱의 `lucide-react`와 같은 판.
/// 자산은 `Tokens.xcassets/icon/<글리프>.imageset`의 SVG(벡터 보존 · template)이고, 라이선스(ISC, 일부 Feather MIT)는 `Resources/Lucide-LICENSE.txt`.
/// SVG는 lucide-react `size={16} strokeWidth={1.75}`와 같다: 16pt, viewBox 24, 선 1.75. 패널 헤더는 14pt로 줄여 쓴다.
/// 색은 쓰는 쪽의 `foregroundStyle`을 따른다(template). 서비스 마크(Notion · Gmail · Slack)는 `SourceIcon`, 에이전트는 마크 없음.
///
/// case = 디자인 README의 역할, rawValue = Lucide 글리프 이름. 역할이 없는 글리프를 더하지 않는다.
public enum TFIcon: String, CaseIterable, Sendable {
    // 디자인 README › Iconography 역할표
    case newChat = "square-pen"
    case more = "ellipsis"
    case chatHistory = "history"
    case pin = "pin"
    case unpin = "pin-off"
    case send = "arrow-up"
    case search = "search"
    case filters = "list-filter"
    case addTask = "plus"
    case disclosure = "chevron-down"
    case project = "folder"
    case checks = "list-checks"
    case result = "file-text"
    case allWork = "list-todo"
    case talk = "message-square"
    case connections = "plug"
    case settings = "settings"
    case account = "circle-user"
    case execution = "shield-check"
    case reports = "bell"
    case shortcuts = "keyboard"
    case back = "chevron-left"
    case popupButton = "chevrons-up-down"
    case reset = "rotate-ccw"
    case paused = "triangle-alert"
    case sentToAgent = "send"
    case opensOutside = "arrow-up-right"
    case refundRequested = "clock"

    // Icon 컴포넌트 README · Icons 자산군
    /// 접힌 행 · 상세로 들어가기 (Icon README의 Disclosure `chevron-right`)
    case disclosureClosed = "chevron-right"
    /// 목록에서 항목 하나를 빼기에만. 면을 닫는 데 쓰지 않는다(닫기 버튼 없음)
    case removeItem = "x"
    /// 검증된 결과 · 끝남 표시 (`ResultStatusLabel`)
    case check = "check"
    /// Assistant 프롬프트 박스의 Attach (OA U1, Lucide `paperclip`)
    case attach = "paperclip"
    /// 레일 맨 위 Review 타일 (OA U1, Lucide `clipboard-check`): 결정 · 결과의 입구
    case review = "clipboard-check"
    /// (OA 외부 세션 PR1, Lucide `laptop`) 레일 셋째 캡슐의 On this Mac이었다. PR-D2에서 그 칸이 Sessions로 합쳐져 레일에는 더 없다 (DS 글리프 세트에는 남겨 둔다)
    case laptop = "laptop"
    /// 레일 첫 캡슐의 Sessions 버튼 (OA PR-D2, DZ 승인 2026-10-22, Lucide 1.48.0 `layers`): Taskforce 세션과 이 Mac의 Claude 세션을 모두 한 곳에서 보는 입구
    case sessions = "layers"
    /// 세션 보기의 복사 (OA 세션 보기 V1, DZ 승인 2026-10-22, Lucide `copy`): 답 밑 오른쪽(마우스를 올리거나 포커스가 있을 때) · 코드 블록 머리(늘 보임)
    case copy = "copy"

    // OA U2: 프로젝트 아이콘 풀 12종 (서버 `PROJECT_ICON_POOL`, DS ProjectIcon). 풀 밖 이름은 `project`(folder)
    case rocket = "rocket"
    case briefcase = "briefcase"
    case flaskConical = "flask-conical"
    case palette = "palette"
    case codeXml = "code-xml"
    case megaphone = "megaphone"
    case bookOpen = "book-open"
    case building2 = "building-2"
    case leaf = "leaf"
    case compass = "compass"
    case target = "target"
    case users = "users"
    /// Ungrouped · Done today 행의 고정된 조용한 아이콘 (선택지가 아니다)
    case ungrouped = "circle-dashed"
    case doneToday = "circle-check"
    /// ContextMenu (Rename · Change icon · Archive · Delete, D4c가 붙인다)
    case rename = "pencil"
    case changeIcon = "shapes"
    case archive = "archive"
    case delete = "trash-2"

    /// 레일 첫 캡슐의 Taskforce bell (OA U3-16, Lucide `bell`): 자산은 Settings Reports와 같은 글리프다. 열거형의 원시값은 유일해야 해서(`reports = "bell"`)
    /// 별도 case가 아니라 같은 글리프를 가리키는 이름이다: 역할이 다르니 쓰는 쪽은 이 이름으로 부른다
    public static var taskforce: TFIcon { .reports }

    /// 프로젝트 아이콘 이름의 글리프 (풀 밖 · 모르는 이름은 folder)
    public static func project(_ name: ProjectIconName) -> TFIcon {
        switch name {
        case .rocket: .rocket
        case .briefcase: .briefcase
        case .flaskConical: .flaskConical
        case .palette: .palette
        case .codeXml: .codeXml
        case .megaphone: .megaphone
        case .bookOpen: .bookOpen
        case .building2: .building2
        case .leaf: .leaf
        case .compass: .compass
        case .target: .target
        case .users: .users
        case .folder: .project
        }
    }

    /// 자산 카탈로그 경로 (`icon` 폴더가 이름공간)
    public var assetName: String { "icon/\(rawValue)" }

    /// 패널 크기 16pt. `size`를 주면 그 크기(헤더 14pt)로 그린다.
    public func image(size: CGFloat = 16) -> some View {
        Image(assetName, bundle: .module)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

#Preview("Icons") {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(120), alignment: .leading), count: 3), alignment: .leading, spacing: 10) {
        ForEach(TFIcon.allCases, id: \.self) { icon in
            HStack(spacing: 8) {
                icon.image()
                Text(icon.rawValue).font(TFFont.meta)
            }
        }
    }
    .foregroundStyle(TFColor.textPrimary)
    .padding()
}

#if os(macOS)
import AppKit

extension TFIcon {
    /// AppKit 메뉴 항목용 (template: 메뉴가 글자색으로 칠한다)
    @MainActor
    public func nsImage(size: CGFloat = 16) -> NSImage? {
        guard let source = TFColor.bundle.image(forResource: assetName), let image = source.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}
#endif
