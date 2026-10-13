import SwiftUI

/// Result status (0.2.0 디자인 시스템 Atoms, 계약 D-4): 결과가 어디까지 왔나. CheckList(passed · pending · unverified)와 다른 줄이다.
/// 에이전트의 완료 보고는 `unconfirmed`이고 체크를 붙이지 않는다. 체크는 검토를 통과했거나(`passedReview`) 사용자가 받았을 때(`accepted`)만.
public struct ResultStatusLabel: View {
    public enum State: String, CaseIterable, Sendable {
        case draft, unconfirmed, inReview, revisionRequested, passedReview, accepted

        public var label: String {
            switch self {
            case .draft: "Draft"
            case .unconfirmed: "Unconfirmed"
            case .inReview: "In review"
            case .revisionRequested: "Revision requested"
            case .passedReview: "Passed review"
            case .accepted: "Accepted"
            }
        }

        /// 검증된 결과만 체크
        public var showsCheck: Bool { self == .passedReview || self == .accepted }
        /// 굵게: 당신이 움직여야 하는 것(수정 요청)과 끝난 것(받음)
        public var isEmphasized: Bool { self == .revisionRequested || self == .accepted }
        /// 보조 톤: 아직 아무도 확인하지 않은 것
        public var isQuiet: Bool { self == .draft || self == .unconfirmed }
    }

    let state: State

    public init(_ state: State) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 4) {
            if state.showsCheck {
                TFIcon.check.image(size: 14)
            }
            Text(state.label)
        }
        .font(state.isEmphasized ? TFFont.footnoteEmphasis : TFFont.footnote)
        .foregroundStyle(state.isQuiet ? TFColor.textSecondary : TFColor.textPrimary)
        .lineLimit(1)
    }
}

#Preview("Result status") {
    VStack(alignment: .leading, spacing: 10) {
        ForEach(ResultStatusLabel.State.allCases, id: \.self) { ResultStatusLabel($0) }
    }
    .padding()
}
