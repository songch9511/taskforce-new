import CoreText
import SwiftUI

/// Keycap (DS Atoms, OA D4b-m-1): 지금 눌러서 동작하는 키를 보인다 (1–4, ⌥ Space). 장식 번호 · 개수로 쓰지 않는다.
/// DS: **IBM Plex Mono 11px** (`.tf-kbd`: 최소 18 × 18, 안쪽 0/4, 모서리 sm, 줄 16) on `fill/keycap`. 글꼴은 이 모듈에 번들한다 (`Resources/Fonts`, OFL 라이선스 파일 · 출처 기록과 함께).
/// 번들한 글꼴은 라틴 부분집합이다: 그 밖의 기호(⌘ · ⌥)는 시스템 글꼴로 넘어간다. return 같은 키는 SF Symbol로 그린다
public struct Keycap: View {
    enum Content {
        case text(String)
        case symbol(String)
    }

    let content: Content

    /// "1" · "Return" · "⌥"
    public init(_ text: String) {
        content = .text(text)
    }

    /// SF Symbol 이름 (예: "return")
    public init(systemImage: String) {
        content = .symbol(systemImage)
    }

    public var body: some View {
        Group {
            switch content {
            case .text(let text): Text(text)
            case .symbol(let name): Image(systemName: name)
            }
        }
        .font(KeycapStyle.font)
        .foregroundStyle(TFColor.textPrimary)
        .lineLimit(1)
        .padding(.horizontal, KeycapStyle.horizontalPadding)
        .frame(minWidth: KeycapStyle.minSize, minHeight: KeycapStyle.minSize)
        .background(TFColor.fillKeycap, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
    }
}

/// Keycap의 모양 값 (DS `.tf-kbd`)과 글꼴 등록. 시험이 값을 고정한다
public enum KeycapStyle {
    /// 번들한 글꼴의 PostScript 이름 · 가족 이름
    public static let fontName = "IBMPlexMono-Regular"
    public static let familyName = "IBM Plex Mono"
    public static let fontSize: CGFloat = 11
    public static let minSize: CGFloat = 18
    public static let horizontalPadding: CGFloat = 4
    /// 번들한 글꼴 파일 · 라이선스 · 출처 기록 (`Resources/Fonts`)
    public static let fontFile = "IBMPlexMono-Regular"
    public static let licenseFile = "IBMPlexMono-OFL"
    public static let sourceFile = "IBMPlexMono-SOURCE"

    /// 이 프로세스에 글꼴을 한 번 올린다. 올리지 못하면 시스템 고정폭으로 대신한다 (Keycap이 사라지지 않게)
    private static let registered: Bool = {
        guard let url = bundledURL(fontFile, "ttf") else { return false }
        var error: Unmanaged<CFError>?
        // 이미 올라가 있어도(다른 모듈이 먼저 올렸다) 쓸 수 있다
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        return CTFontCreateWithName(fontName as CFString, fontSize, nil) .familyNameMatches(familyName)
    }()

    public static var isFontAvailable: Bool { registered }

    public static var font: Font {
        registered ? .custom(fontName, fixedSize: fontSize) : .system(size: fontSize, design: .monospaced)
    }

    /// 번들 안의 파일 (`.process`로 복사되면 바로 아래에, 폴더가 남으면 `Fonts` 아래에 있다)
    static func bundledURL(_ name: String, _ ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext) ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fonts")
    }
}

extension CTFont {
    fileprivate func familyNameMatches(_ family: String) -> Bool {
        (CTFontCopyFamilyName(self) as String) == family
    }
}

#Preview("Keycap") {
    HStack(spacing: 8) {
        Keycap("1")
        Keycap("2")
        Keycap("Return")
        Keycap("⌥")
        Keycap("Space")
        Keycap(systemImage: "return")
    }
    .padding()
}
