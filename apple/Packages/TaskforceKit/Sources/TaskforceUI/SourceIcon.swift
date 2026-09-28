import SwiftUI
import TaskforceKit

/// Source icon (Figma 10:23): 근거가 어디서 왔는지 보여 주는 타일. 서비스 이름은 글자로 쓰지 않고 로고(단색)로 보여 준다.
/// 큰 글자에서 함께 커진다 (@ScaledMetric, 스트레스 E3).
public struct SourceIcon: View {
    public enum Size: Sendable {
        /// 20pt
        case m
        /// 14pt
        case s
    }

    let service: SourceService
    let size: Size

    @ScaledMetric(relativeTo: .subheadline) private var mSide: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var sSide: CGFloat = 14

    public init(_ service: SourceService, size: Size = .m) {
        self.service = service
        self.size = size
    }

    private var side: CGFloat { size == .m ? mSide : sSide }
    /// M 5 · S 3 (Figma)
    private var radius: CGFloat { size == .m ? side / 4 : side * 3 / 14 }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(TFColor.bgElevated)
            .overlay(shape.strokeBorder(TFColor.borderDefault, lineWidth: 1))
            .overlay { glyph }
            .frame(width: side, height: side)
            .accessibilityElement()
            .accessibilityLabel(service.accessibilityName)
    }

    @ViewBuilder
    private var glyph: some View {
        if let asset = assetName {
            Image(asset, bundle: .module)
                .renderingMode(.template)
                .resizable()
                .foregroundStyle(TFColor.textPrimary)
        } else if case .manual(let kind) = service {
            // 연동이 아닌 원문: 로고가 없으니 종류 기호 (Figma에 없는 경우, 같은 타일 · 글자색으로 구성)
            Image(systemName: kind.symbolName)
                .font(.system(size: side * 0.5, weight: .semibold))
                .foregroundStyle(TFColor.textPrimary)
        }
    }

    private var assetName: String? {
        let suffix = size == .m ? "m" : "s"
        return switch service {
        case .notion: "source/notion-\(suffix)"
        case .slack: "source/slack-\(suffix)"
        case .gmail: "source/gmail-\(suffix)"
        case .googleMeet: "source/google-meet-\(suffix)"
        case .manual: nil
        }
    }
}

/// Source stack (Figma 11:214 · 11:949): 타일을 겹치고 왼쪽이 위. 몇 개를 그릴지는 `SourceStackLayout`이 정한다.
public struct SourceStack: View {
    let layout: SourceStackLayout.Result
    let size: SourceIcon.Size

    @ScaledMetric(relativeTo: .subheadline) private var mSide: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var sSide: CGFloat = 14

    /// Sources 묶음 머리 (M): 같은 서비스는 한 번, 4개 이상이면 3개 + "+N"
    public init(services: [SourceService]) {
        layout = SourceStackLayout.medium(services)
        size = .m
    }

    /// 근거 줄 끝 (S): 맨 앞 출처를 뺀 나머지
    public init(others: [SourceService]) {
        layout = SourceStackLayout.small(others: others)
        size = .s
    }

    private var side: CGFloat { size == .m ? mSide : sSide }
    /// M 6 · S 4
    private var overlap: CGFloat { size == .m ? side * 0.3 : side * 4 / 14 }

    public var body: some View {
        HStack(spacing: -overlap) {
            ForEach(Array(layout.icons.enumerated()), id: \.offset) { index, service in
                SourceIcon(service, size: size)
                    .zIndex(Double(layout.icons.count - index + 1))
            }
            if layout.more > 0 {
                Text("+\(layout.more)")
                    .font(.system(size: size == .m ? side / 2 : side * 8 / 14, weight: .semibold))
                    .foregroundStyle(TFColor.textPrimary)
                    .padding(.leading, overlap + side * 0.15)
                    .padding(.trailing, side / 5)
                    .frame(minWidth: side, minHeight: side, maxHeight: side)
                    .background(chip.fill(TFColor.fillKeycap))
                    .overlay(chip.strokeBorder(TFColor.borderDefault, lineWidth: 1))
                    .zIndex(0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var chip: RoundedRectangle {
        RoundedRectangle(cornerRadius: size == .m ? TFRadius.sm : 3, style: .continuous)
    }

    private var accessibilityText: String {
        let names = layout.icons.map(\.accessibilityName).joined(separator: ", ")
        return layout.more > 0 ? "\(names), and \(layout.more) more" : names
    }
}

#Preview("Source icon") {
    VStack(spacing: 16) {
        HStack(spacing: 16) {
            ForEach([SourceService.notion, .slack, .gmail, .googleMeet, .manual(.note)], id: \.self) { SourceIcon($0) }
        }
        HStack(spacing: 16) {
            ForEach([SourceService.notion, .slack, .gmail, .googleMeet, .manual(.message)], id: \.self) { SourceIcon($0, size: .s) }
        }
        HStack(spacing: 24) {
            SourceStack(services: [.notion, .slack])
            SourceStack(services: [.notion, .slack, .gmail])
            SourceStack(services: [.notion, .slack, .gmail, .googleMeet, .manual(.note)])
        }
        HStack(spacing: 24) {
            SourceStack(others: [.notion])
            SourceStack(others: [.notion, .slack])
            SourceStack(others: [.notion, .slack, .gmail, .notion, .slack])
        }
    }
    .padding()
    .background(TFColor.bgSurface)
}
