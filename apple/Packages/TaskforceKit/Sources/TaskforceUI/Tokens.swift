import SwiftUI

// Figma 디자인 시스템 v1 (jDMRGHWMRXeNUILfi11xvf) Foundations 13:960.
// 값이 다르면 Figma 변수가 기준이다. 색은 Asset Catalog 색 세트(Any/Dark)로 두고 이름은 Figma 변수 이름 그대로다.
// Native 재설계(156:6)의 변수도 같은 규칙이다.

/// Color 컬렉션 (13:983). 이름 = Figma 변수 이름(`color/` 뺀 것) = Asset Catalog 색 세트 경로.
public enum TFColor {
    public static let bgCanvas = color(.bgCanvas)
    public static let bgSurface = color(.bgSurface)
    public static let bgElevated = color(.bgElevated)
    /// 선택 행 면: 라이트 검정 8% · 다크 흰색 14% (반투명 회색, 청색은 포커스 · 링크 · 커서에만)
    public static let bgSelected = color(.bgSelected)
    /// 런처 검색줄 · 액션 바 유리 (macOS 26 전, 반투명)
    public static let bgGlass = color(.bgGlass)
    /// ⌘K · 범위 메뉴 면 (반투명)
    public static let bgMenu = color(.bgMenu)

    public static let fillAccent = color(.fillAccent)
    public static let fillInverse = color(.fillInverse)
    public static let fillKeycap = color(.fillKeycap)
    public static let fillSecondary = color(.fillSecondary)

    public static let textPrimary = color(.textPrimary)
    public static let textSecondary = color(.textSecondary)
    public static let textAccent = color(.textAccent)
    public static let textOnAccent = color(.textOnAccent)
    public static let textInverse = color(.textInverse)
    /// 링크와 본문 안 동작
    public static let textLink = color(.textLink)
    /// 선택 행 위의 보조 글자 (bg/selected 위에서도 4.5:1. 다크 `#B9B9BE`는 2026-10-03 Figma에서 4.5:1에 맞춰 고친 값)
    public static let textSecondarySelected = color(.textSecondarySelected)

    public static let statusOverdue = color(.statusOverdue)
    /// 선택 행 위의 지난 · 오늘 기한 (bg/selected 위에서도 4.5:1. 다크 `#FFA099`는 2026-10-03 Figma에서 4.5:1에 맞춰 고친 값)
    public static let statusOverdueSelected = color(.statusOverdueSelected)

    public static let borderDefault = color(.borderDefault)
    public static let borderControl = color(.borderControl)
    public static let borderAccent = color(.borderAccent)

    /// 원문 슬립 (종이 위 인용)
    public static let sourcePaper = color(.sourcePaper)
    public static let sourceText = color(.sourceText)
    public static let sourceMeta = color(.sourceMeta)

    /// 설정 창 바탕 (Codex 설정)
    public static let settingsWindow = color(.settingsWindow)
    /// 설정 사이드바 · 런처 목록 면
    public static let settingsSidebar = color(.settingsSidebar)
    /// 회색 버튼 · 선택 알약 · 검색칸 면
    public static let settingsFill = color(.settingsFill)
    /// 카드 · 패널 테두리, 설정 구분선
    public static let settingsLine = color(.settingsLine)
    /// 설정 본문 · 시트 (카드 bg/elevated가 한 단계 위)
    public static let settingsContent = color(.settingsContent)

    /// 색 토큰 이름. 모든 토큰은 여기를 거친다 (TaskforceUITests가 모든 이름의 색 세트 · Light/Dark 값을 확인한다).
    enum Name: String, CaseIterable {
        case bgCanvas = "bg/canvas"
        case bgSurface = "bg/surface"
        case bgElevated = "bg/elevated"
        case bgSelected = "bg/selected"
        case bgGlass = "bg/glass"
        case bgMenu = "bg/menu"
        case fillAccent = "fill/accent"
        case fillInverse = "fill/inverse"
        case fillKeycap = "fill/keycap"
        case fillSecondary = "fill/secondary"
        case textPrimary = "text/primary"
        case textSecondary = "text/secondary"
        case textAccent = "text/accent"
        case textOnAccent = "text/on-accent"
        case textInverse = "text/inverse"
        case textLink = "text/link"
        case textSecondarySelected = "text/secondary-selected"
        case statusOverdue = "status/overdue"
        case statusOverdueSelected = "status/overdue-selected"
        case borderDefault = "border/default"
        case borderControl = "border/control"
        case borderAccent = "border/accent"
        case sourcePaper = "source/paper"
        case sourceText = "source/text"
        case sourceMeta = "source/meta"
        case settingsWindow = "settings/window"
        case settingsSidebar = "settings/sidebar"
        case settingsFill = "settings/fill"
        case settingsLine = "settings/line"
        case settingsContent = "settings/content"
    }

    /// 색 세트가 든 번들 (테스트가 같은 번들에서 읽는다)
    static var bundle: Bundle { .module }

    private static func color(_ name: Name) -> Color {
        Color(name.rawValue, bundle: .module)
    }
}

/// Spacing (13:1214): 4pt 단위
public enum TFSpace {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

/// Radius (13:1214): 칩 5 · 행 8 · 카드 18 · 창 26, 버튼은 캡슐.
/// Native 재설계(156:6): 런처 · 설정 창 외곽 18(`window`), 목록 | 상세 패널 · 설정 카드 12(`panel`).
/// `xl` 26은 iPhone이 아직 쓰므로 둔다.
public enum TFRadius {
    public static let sm: CGFloat = 5
    public static let md: CGFloat = 8
    public static let lg: CGFloat = 18
    public static let xl: CGFloat = 26
    /// 런처 · 설정 창 외곽 (760×480)
    public static let window: CGFloat = 18
    /// 런처 목록 | 상세 패널, 설정 카드
    public static let panel: CGFloat = 12
}

/// Typography (13:1161). SF Pro Regular · Semibold만 (400 · 600).
/// iOS는 Dynamic Type 글자 스타일에 맞춘다 (Callout 15 → `.subheadline`).
/// macOS의 글자 스타일은 크기가 달라서(본문 13) Figma 크기를 그대로 쓴다 (macOS에는 Dynamic Type이 없다).
/// 아래 "Native 재설계" 묶음은 156:6 화면이 글자 스타일 없이 쓰는 크기다 (검색 22 · 행 14 · 보조 12 · 키 11).
public enum TFFont {
    #if os(macOS)
    /// App/Title 20 semibold
    public static let title = Font.system(size: 20, weight: .semibold)
    /// App/Headline 17 semibold
    public static let headline = Font.system(size: 17, weight: .semibold)
    /// App/Body 17
    public static let body = Font.system(size: 17)
    /// App/Callout 15
    public static let callout = Font.system(size: 15)
    /// App/Footnote 13
    public static let footnote = Font.system(size: 13)
    /// App/Caption 12 semibold
    public static let caption = Font.system(size: 12, weight: .semibold)
    /// Source stack "+N" (10 semibold)
    public static let badge = Font.system(size: 10, weight: .semibold)

    // Native 재설계 (156:6)
    /// 런처 검색줄 22
    public static let search = Font.system(size: 22)
    /// 설정 페이지 제목 22 semibold
    public static let pageTitle = Font.system(size: 22, weight: .semibold)
    /// Mac 목록 행 제목 14
    public static let row = Font.system(size: 14)
    /// 선택된 Mac 목록 행 제목 14 semibold
    public static let rowSelected = Font.system(size: 14, weight: .semibold)
    /// 섹션 머리 · 행 오른쪽 기한 · 설정 부제 · Show N More 12
    public static let meta = Font.system(size: 12)
    /// 빈 화면 제목 15 semibold
    public static let calloutEmphasis = Font.system(size: 15, weight: .semibold)
    /// 액션 바 Return 동작 · 설정 그룹 이름 · Strong 버튼 13 semibold
    public static let footnoteEmphasis = Font.system(size: 13, weight: .semibold)
    /// 키 글자 11 semibold
    public static let key = Font.system(size: 11, weight: .semibold)
    #else
    public static let title = Font.title3.weight(.semibold)
    public static let headline = Font.headline
    public static let body = Font.body
    public static let callout = Font.subheadline
    public static let footnote = Font.footnote
    public static let caption = Font.caption.weight(.semibold)
    public static let badge = Font.caption2.weight(.semibold)

    public static let search = Font.title2
    public static let pageTitle = Font.title2.weight(.semibold)
    public static let row = Font.subheadline
    public static let rowSelected = Font.subheadline.weight(.semibold)
    public static let meta = Font.caption
    public static let calloutEmphasis = Font.subheadline.weight(.semibold)
    public static let footnoteEmphasis = Font.footnote.weight(.semibold)
    public static let key = Font.caption2.weight(.semibold)
    #endif
}

/// 로고 · 서비스 아이콘 (단색 template)
public enum TFImage {
    /// Logo/Mark 3:319 (비율 720:510)
    public static var logoMark: Image { Image("logo/mark", bundle: .module) }
    public static let logoMarkAspectRatio: CGFloat = 720.0 / 510.0
    /// Google "G" (표준 색 그라데이션, 18pt). Google Sign-In SDK 10.0.0의 버튼 아이콘(`GoogleSignIn/Sources/Resources/google*.png`) 그대로.
    /// Google 브랜드 규칙: 색 · 모양을 바꾸지 않고 흰 바탕 위에 둔다.
    public static var googleG: Image { Image("logo/google-g", bundle: .module) }
}

#if os(macOS)
import AppKit

extension TFImage {
    /// 메뉴 막대용 로고 마크 (template: 메뉴 막대가 밝기에 맞춰 칠한다)
    @MainActor
    public static func logoMarkTemplate(height: CGFloat) -> NSImage? {
        guard let source = Bundle.module.image(forResource: "logo/mark"), let image = source.copy() as? NSImage else { return nil }
        image.size = NSSize(width: (height * logoMarkAspectRatio).rounded(), height: height)
        image.isTemplate = true
        return image
    }
}
#endif
