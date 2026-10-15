import SwiftUI
import TaskforceKit

/// SourceMark (0.2.0 디자인 시스템 Atoms, OA U2): 인용이 어느 서비스에서 왔는지 보이는 작은 타일. 마크는 **서비스의 공식 마크 그대로**(thesvg `public/icons/<service>/default.svg`,
/// DS 아티팩트의 SourceMark와 같은 파일), 두 테마 모두 서비스 자기 색이다. 다시 칠하거나 그리거나 흉내 내지 않고 Taskforce 마크와 섞지 않는다.
/// - 타일: 18pt(`sm`) · 24(`md`) · 36(`lg`), `border/default` 1pt 선 · `bg/elevated` · 모서리 5(DS `radius-sm`), 마크는 타일의 약 62% (`md` · `lg`는 안쪽 여백 3 · 6)
/// - 마크가 없는 출처(붙여 넣은 원문 · 메모 · thesvg에 없는 서비스)는 **점선 빈 타일**이다 (DS: "A source with no mark renders a dashed blank tile")
/// - 기존 `SourceIcon`(단색 · 종류 기호)은 게이트가 꺼진 화면이 그대로 쓴다: 이 부품은 새 Issues 화면의 인용(`SourceQuote(…, usesSourceMark: true)`)만 쓴다
public struct SourceMark: View {
    public enum Size: Sendable {
        case sm, md, lg

        var side: CGFloat {
            switch self {
            case .sm: 18
            case .md: 24
            case .lg: 36
            }
        }

        var radius: CGFloat {
            switch self {
            case .sm: 5
            case .md: 6
            case .lg: 9
            }
        }

        /// 마크가 차지하는 비율 (DS `.tf-source img`: 기본 62%, md · lg는 타일 안쪽 여백 3 · 6 뒤 전부)
        var markSide: CGFloat {
            switch self {
            case .sm: side * 0.62
            case .md: side - 6
            case .lg: side - 12
            }
        }
    }

    let service: SourceService
    let size: Size

    public init(_ service: SourceService, size: Size = .sm) {
        self.service = service
        self.size = size
    }

    /// 서비스의 마크 자산 이름. 마크가 없으면 nil (점선 빈 타일)
    nonisolated public static func assetName(for service: SourceService) -> String? {
        switch service {
        case .slack: "source-mark/slack"
        case .notion: "source-mark/notion"
        case .gmail: "source-mark/gmail"
        case .googleMeet: "source-mark/google-meet"
        case .manual: nil
        }
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        Group {
            if let asset = Self.assetName(for: service) {
                shape
                    .fill(TFColor.bgElevated)
                    .overlay(shape.strokeBorder(TFColor.borderDefault, lineWidth: 1))
                    .overlay {
                        Image(asset, bundle: .module)
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: size.markSide, height: size.markSide)
                    }
            } else {
                shape
                    .strokeBorder(TFColor.borderDefault, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .frame(width: size.side, height: size.side)
        .accessibilityElement()
        .accessibilityLabel(Self.assetName(for: service) == nil ? "\(service.accessibilityName), no mark" : service.accessibilityName)
    }
}

#Preview("SourceMark") {
    HStack(spacing: 12) {
        ForEach([SourceService.slack, .notion, .gmail, .googleMeet, .manual(.note)], id: \.self) { SourceMark($0) }
    }
    .padding(16)
    .background(TFColor.bgPanel)
}
