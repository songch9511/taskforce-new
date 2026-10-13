import SwiftUI

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
