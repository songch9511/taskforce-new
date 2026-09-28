import SwiftUI

// Figma 디자인 시스템 v1 (jDMRGHWMRXeNUILfi11xvf) Foundations 13:960.
// 값이 다르면 Figma 변수가 기준이다. 색은 Asset Catalog 색 세트(Any/Dark)로 두고 이름은 Figma 변수 이름 그대로다.

/// Color 컬렉션 (13:983)
public enum TFColor {
    public static let bgCanvas = named("bg/canvas")
    public static let bgSurface = named("bg/surface")
    public static let bgElevated = named("bg/elevated")
    public static let bgSelected = named("bg/selected")

    public static let fillAccent = named("fill/accent")
    public static let fillInverse = named("fill/inverse")
    public static let fillKeycap = named("fill/keycap")
    public static let fillSecondary = named("fill/secondary")

    public static let textPrimary = named("text/primary")
    public static let textSecondary = named("text/secondary")
    public static let textAccent = named("text/accent")
    public static let textOnAccent = named("text/on-accent")
    public static let textInverse = named("text/inverse")

    public static let statusOverdue = named("status/overdue")

    public static let borderDefault = named("border/default")
    public static let borderControl = named("border/control")
    public static let borderAccent = named("border/accent")

    private static func named(_ name: String) -> Color {
        Color(name, bundle: .module)
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

/// Radius (13:1214): 칩 5 · 행 8 · 카드 18 · 창 26, 버튼은 캡슐
public enum TFRadius {
    public static let sm: CGFloat = 5
    public static let md: CGFloat = 8
    public static let lg: CGFloat = 18
    public static let xl: CGFloat = 26
}

/// Typography (13:1161). 굵기는 400 · 600만.
/// iOS는 Dynamic Type 글자 스타일에 맞춘다 (Callout 15 → `.subheadline`).
/// macOS의 글자 스타일은 크기가 달라서(본문 13) Figma 크기를 그대로 쓴다 (macOS에는 Dynamic Type이 없다).
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
    #else
    public static let title = Font.title3.weight(.semibold)
    public static let headline = Font.headline
    public static let body = Font.body
    public static let callout = Font.subheadline
    public static let footnote = Font.footnote
    public static let caption = Font.caption.weight(.semibold)
    public static let badge = Font.caption2.weight(.semibold)
    #endif
}

/// 로고 · 서비스 아이콘 (단색 template)
public enum TFImage {
    /// Logo/Mark 3:319 (비율 720:510)
    public static var logoMark: Image { Image("logo/mark", bundle: .module) }
    public static let logoMarkAspectRatio: CGFloat = 720.0 / 510.0
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
