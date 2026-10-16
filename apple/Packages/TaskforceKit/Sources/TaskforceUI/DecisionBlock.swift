import SwiftUI
import TaskforceKit

/// AnswerOption (0.2.0 디자인 시스템 Molecules): 결정의 답 한 줄. 번호 키 · 사용자의 말로 쓴 결과 · 힌트 하나까지.
/// 디자인 README: 보이는 결정의 답에만 번호를 붙인다. 힌트(`Suggested`)는 많아야 하나, 색이 아니라 글로.
/// 답을 고른 뒤에는 잠기고 고른 것에 check가 붙는다. **Review는 서버가 받았다고 답한 뒤에만 그렇게 그린다** (`Phase`): 보내는 중에는 check도 완료 표시도 없다.
public struct AnswerOption: View {
    public enum Phase: Sendable, Hashable {
        /// 누를 수 있다
        case ready
        /// 이 답을 보내는 중: 누를 수 없고, check가 아니라 진행 표시다 (결과를 아직 모른다)
        case sending
        /// 서버가 받았다고 답했다 (고른 답: semibold + check)
        case chosen
        /// 눌러 볼 수 없다 (다른 답을 보내는 중 · 오프라인)
        case locked
    }

    let index: Int?
    let label: String
    let hint: String?
    let phase: Phase
    /// 번호 글(keycap)을 그리지 않는다: 키는 그대로 답한다 (DS "Numbers show only with four answers")
    let quietKey: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    public init(index: Int? = nil, label: String, hint: String? = nil, phase: Phase = .ready, quietKey: Bool = false, action: @escaping () -> Void) {
        self.index = index
        self.label = label
        self.hint = hint
        self.phase = phase
        self.quietKey = quietKey
        self.action = action
    }

    /// 디자인 `--answer-row`: 답 한 줄의 최소 높이 (런처 행 높이)
    public static let minHeight: CGFloat = 40

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                if let index, !quietKey { Keycap(String(index)) }
                Text(label)
                    .font(.system(size: 15, weight: phase == .chosen ? .semibold : .regular))
                    .tracking(-0.24)
                    .foregroundStyle(phase == .locked || phase == .sending ? TFColor.textSecondary : TFColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                trailing
            }
            .padding(.horizontal, TFSpace.md)
            .padding(.vertical, TFSpace.sm)
            .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
            .background(hovering && phase == .ready || phase == .chosen ? TFColor.bgSelected : TFColor.bgField, in: shape)
            .overlay(shape.strokeBorder(contrast == .increased ? TFColor.borderControl : .clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(phase != .ready)
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(index.map { "Press \($0)" } ?? "")
        .accessibilityValue(Self.accessibilityValue(phase))
        .accessibilityAddTraits(phase == .chosen ? .isSelected : [])
    }

    @ViewBuilder
    private var trailing: some View {
        switch phase {
        case .chosen:
            TFIcon.check.image(size: 16)
                .foregroundStyle(TFColor.textPrimary)
                .accessibilityHidden(true)
        case .sending:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        case .ready, .locked:
            if let hint {
                Text(hint)
                    .font(TFFont.meta)
                    .foregroundStyle(TFColor.textSecondarySelected)
            }
        }
    }

    /// VoiceOver 값: 보내는 중 · 고른 답 (그 밖에는 말하지 않는다)
    nonisolated public static func accessibilityValue(_ phase: Phase) -> String {
        switch phase {
        case .sending: "Sending"
        case .chosen: "Chosen"
        case .ready, .locked: ""
        }
    }
}

/// DecisionBlock (0.2.0 디자인 시스템 Organisms): 번호 붙은 답이 있는 질문 하나. Review 화면이 보이는 것의 거의 전부다.
/// meta("Needs your answer · 프로젝트") → 질문 → 질문 바로 아래 원문(`source`: SourceQuote) → 답 둘이나 셋.
/// 답을 읽는 것은 해결이 아니다: 해결은 사용자가 답을 골랐을 때뿐이고, 이 부품은 보내는 일을 하지 않는다 (`onAnswer`만 부른다).
/// 디자인에 있는 "답한 뒤 outcome + Undo"는 S4b(C3)의 몫이라 여기에 없다: v1에는 되돌리기 의미가 없다.
/// `note`: 보낸 답이 거절됐거나 결과를 확인하지 못했을 때의 한 줄 (성공 안내가 아니다)
/// `facts`(디자인에 없는 한 가지 더함, `s4-mac-notes.md`): 질문이 v1의 확인 이유뿐이라(바뀐 사실이 아니다) 결정의 대상 · 값이 사라지지 않게, 머리에서 잘린 전체 제목과 확인할 기한을 질문 아래에 둔다.
public struct DecisionBlock<Source: View>: View {
    public struct Answer: Identifiable, Sendable, Hashable {
        public let index: Int
        public let label: String
        public let hint: String?
        public let phase: AnswerOption.Phase

        public var id: Int { index }

        public init(index: Int, label: String, hint: String? = nil, phase: AnswerOption.Phase = .ready) {
            self.index = index
            self.label = label
            self.hint = hint
            self.phase = phase
        }
    }

    /// 질문 아래 한두 줄의 사실: v1 확인 요청의 전체 제목(머리에 다 들어가지 않을 때) · 확인할 기한. 디자인에는 없다 (아래 문서)
    public struct Fact: Identifiable, Sendable, Hashable {
        public enum Style: Sendable, Hashable {
            /// 결정의 대상 (전체 제목)
            case subject
            /// 값 (`Due Fri`)
            case value
            /// 지났거나 오늘인 기한 (빨강, 서버 이유가 없을 때 같은 기준 `DueText.isUrgent`)
            case urgent
        }

        public let text: String
        public let style: Style

        public var id: String { "\(style)-\(text)" }

        public init(_ text: String, _ style: Style = .value) {
            self.text = text
            self.style = style
        }
    }

    let meta: String
    let question: String
    let facts: [Fact]
    let answers: [Answer]
    let note: String?
    let quietKeys: Bool
    let onAnswer: (Int) -> Void
    let source: Source

    /// - meta: 비면 메타 줄이 없다 (OA U3-25: Taskforce 대화는 확인된 프로젝트 이름만 말하고 "Needs your answer"는 말하지 않는다 — 질문이 이미 질문이다)
    /// - quietKeys: 답에 번호 글을 그리지 않는다 (답이 넷일 때만 번호를 보인다, DS). 키 1 · 2는 그대로 답한다
    public init(
        meta: String, question: String, facts: [Fact] = [], answers: [Answer], note: String? = nil, quietKeys: Bool = false, onAnswer: @escaping (Int) -> Void,
        @ViewBuilder source: () -> Source
    ) {
        self.quietKeys = quietKeys
        self.meta = meta
        self.question = question
        self.facts = facts
        self.answers = answers
        self.note = note
        self.onAnswer = onAnswer
        self.source = source()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !meta.isEmpty {
                Text(meta)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .padding(.top, 2)
                    .padding(.bottom, TFSpace.sm)
            }
            Text(question)
                .font(TFFont.headline)
                .tracking(-0.374)
                .foregroundStyle(TFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, facts.isEmpty ? TFSpace.md : TFSpace.xs)
                .accessibilityAddTraits(.isHeader)
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(facts) { fact in
                        Text(fact.text)
                            .font(fact.style == .subject ? TFFont.callout : TFFont.footnote)
                            .foregroundStyle(fact.style == .subject ? TFColor.textPrimary : (fact.style == .urgent ? TFColor.statusOverdue : TFColor.textSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, TFSpace.md)
            }
            source
                .padding(.bottom, TFSpace.md)
            VStack(spacing: Self.answerGap) {
                ForEach(answers) { answer in
                    AnswerOption(index: answer.index, label: answer.label, hint: answer.hint, phase: answer.phase, quietKey: quietKeys) { onAnswer(answer.index) }
                }
            }
            if let note {
                Text(note)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, TFSpace.md)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Decision")
    }

    /// 디자인 `.tf-answers`: 답 사이 6pt
    public static var answerGap: CGFloat { 6 }
}

#Preview("Decision block") {
    DecisionBlock(
        meta: "Needs your answer · Shape launch", question: "Not sure it's yours",
        answers: [
            .init(index: 1, label: "Confirm"),
            .init(index: 2, label: "Dismiss"),
        ],
        onAnswer: { _ in }
    ) {
        SourceQuote(
            service: .gmail, place: "Thread", time: "Today 10:42", text: "Could we do the core launch on Thursday instead?",
            openTitle: "Open in Gmail", onOpen: {}
        )
    }
    .padding(16)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
