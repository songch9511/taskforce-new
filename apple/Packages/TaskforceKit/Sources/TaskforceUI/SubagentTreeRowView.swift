#if os(macOS)
import SwiftUI
import TaskforceKit

/// 트리 줄의 값 규칙 (뷰가 그대로 쓴다: 시험이 고정한다). 뷰 밖에 두어 메인 액터에 묶이지 않는다
public enum SubagentTreeLook {
    /// 단계마다 들여쓰는 폭 · 들여쓰기가 멈추는 단계 (옆줄 폭 256에서 제목이 모자라지 않게)
    public static let indentStep: CGFloat = 12
    public static let maxIndentLevels = 4
    /// 꺾쇠 칸의 폭 (자식이 없는 줄도 같은 폭을 비워 제목이 같은 줄에 선다)
    public static let chevronWidth: CGFloat = 20

    /// 이 줄의 들여쓰기 (넷째 단계에서 멈춘다)
    public static func indent(level: Int) -> CGFloat { CGFloat(min(max(level, 0), maxIndentLevels)) * indentStep }

    /// 줄의 접근성 이름: "{종류}, {이름}, {상태}". 접힌 분기면 끝 글을 덧붙인다 ("…, Running, Running 2 · Failed 1")
    public static func accessibilityName(_ row: SubagentTreeRow, now: Date) -> String {
        let name = row.task.accessibleName(now: now)
        return row.branchSummary.map { "\(name), \($0)" } ?? name
    }

    /// 꺾쇠의 접근성 값: 자식이 있는 줄만 "Collapsed" · "Expanded" (macOS의 SwiftUI에는 펼침을 말하는 속성이 없어 값으로 말한다: 21-5). 자식이 없으면 nil
    public static func accessibilityValue(_ row: SubagentTreeRow) -> String? {
        guard row.hasChildren else { return nil }
        return row.isExpanded ? SessionViewCopy.expanded : SessionViewCopy.collapsed
    }

    /// 둘째 줄 "종류 · 상태 · 시간": 실패한 일의 "Failed" 한 단어만 굵다 (600 `text/primary`, 빨강 없음). 나머지는 부르는 쪽의 글꼴 · 색
    public static func metaText(_ task: TaskforceKit.BackgroundTask, now: Date) -> Text {
        let parts = task.meta(now: now).components(separatedBy: " · ")
        var result = Text(verbatim: "")
        for (index, part) in parts.enumerated() {
            if index > 0 { result = result + Text(verbatim: " · ") }
            if task.status == .failed, part == BackgroundTaskStatus.failed.word {
                result = result + Text(verbatim: part).font(TFFont.footnoteEmphasis).foregroundStyle(TFColor.textPrimary)
            } else {
                result = result + Text(verbatim: part)
            }
        }
        return result
    }
}

/// 하위 에이전트 트리의 줄 하나 (에이전트 트리 T1): 세션 패널 옆줄이 첫 사용처이고 프로젝트 화면(T3m)이 그대로 다시 쓴다. 펼침 상태는 Kit `SubagentTreeExpansion`이 갖고, 이 줄은 값만 그린다.
/// - 모양: 옆줄의 일 줄(제목 15/20 · 둘째 줄 "종류 · 상태 · 시간" 13/18)에 단계마다 들여쓰기(12pt, 넷째 단계에서 멈춘다)와 자식이 있는 줄의 꺾쇠 칸을 더했다. 이름은 모델이 쓴 description뿐이다
/// - 줄을 누르면 `onOpen`(기존 꼬리 보기). 꺾쇠는 `onToggle`(접고 편다)이고 줄과 따로 눌린다. 접힌 분기의 끝에는 그 아래의 "Running n · Failed n"만 (숫자와 기존 낱말뿐: 새 문구 없음)
/// - 접근성: 줄은 이름만("{종류}, {이름}, {상태}" + 접힌 분기면 끝 글), 꺾쇠는 같은 이름에 접힘/펼침을 **값**("Collapsed" · "Expanded")으로 말한다 (21-5 접근성 표). 실패한 줄의 "Failed"는 굵다 (빨강 없음)
/// - 움직임은 `TFMotion`(꺾쇠 200ms)이고 동작 줄이기에서는 움직이지 않는다
public struct SubagentTreeRowView: View {
    let row: SubagentTreeRow
    let now: Date
    let reduceMotion: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void
    @State private var hovering = false

    public init(row: SubagentTreeRow, now: Date, reduceMotion: Bool = false, onOpen: @escaping () -> Void, onToggle: @escaping () -> Void) {
        self.row = row
        self.now = now
        self.reduceMotion = reduceMotion
        self.onOpen = onOpen
        self.onToggle = onToggle
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: TFSpace.sm) {
                        Text(row.task.title)
                            .font(TFFont.callout)
                            .tracking(-0.24)
                            .foregroundStyle(TFColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        if let summary = row.branchSummary {
                            Text(verbatim: summary)
                                .font(TFFont.footnote)
                                .tracking(-0.08)
                                .monospacedDigit()
                                .foregroundStyle(hovering ? TFColor.textSecondarySelected : TFColor.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    SubagentTreeLook.metaText(row.task, now: now)
                        .font(TFFont.footnote)
                        .tracking(-0.08)
                        .monospacedDigit()
                        .foregroundStyle(hovering ? TFColor.textSecondarySelected : TFColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(EdgeInsets(top: 10, leading: TFSpace.sm + SubagentTreeLook.chevronWidth, bottom: 10, trailing: TFSpace.sm))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SubagentTreeLook.accessibilityName(row, now: now))
            .accessibilityAddTraits(.isButton)
            if row.hasChildren {
                Button(action: onToggle) {
                    TFIcon.disclosureClosed.image(size: 12)
                        .foregroundStyle(hovering ? TFColor.textPrimary : TFColor.textSecondary)
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                        .animation(TFMotion.move(TFMotion.disclosureFlip, reduceMotion: reduceMotion), value: row.isExpanded)
                        .frame(width: SubagentTreeLook.chevronWidth, height: 28)
                        .padding(.leading, TFSpace.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SubagentTreeLook.accessibilityName(row, now: now))
                .accessibilityValue(SubagentTreeLook.accessibilityValue(row) ?? "")
                .accessibilityAddTraits(.isButton)
            }
        }
        .background(hovering ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
        .padding(.leading, SubagentTreeLook.indent(level: row.level))
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        .accessibilityElement(children: .contain)
    }
}
#endif
