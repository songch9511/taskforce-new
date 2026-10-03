import SwiftUI

/// Mac list row (Figma 158:3908, 4차 수정): 상태 표시 없이 제목 한 줄 + 오른쪽 기한(또는 Review의 동사) + 바뀜 점.
/// 높이 36, r8, 안쪽 10. 선택 행은 bg/selected + 제목 semibold, 오른쪽 글자는 선택 전용 색(4.5:1)으로 바꾼다.
/// - `urgent`: 기한이 지났거나 오늘 (`DueText.isUrgent`) → status/overdue
/// - `changed`: 마지막으로 본 뒤 바뀜 (`SeenTracker.showsDot`) → 6pt Ink 점
/// - `dimmed`: 오늘 끝낸 할 일 → 제목을 보조 색으로 (취소선 없음)
/// VoiceOver: "제목, 기한[, Changed]"
public struct MacListRow: View {
    let title: String
    let accessory: String?
    let urgent: Bool
    let changed: Bool
    let selected: Bool
    let dimmed: Bool

    public init(title: String, accessory: String? = nil, urgent: Bool = false, changed: Bool = false, selected: Bool = false, dimmed: Bool = false) {
        self.title = title
        self.accessory = accessory
        self.urgent = urgent
        self.changed = changed
        self.selected = selected
        self.dimmed = dimmed
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(selected ? TFFont.rowSelected : TFFont.row)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let accessory {
                Text(accessory)
                    .font(TFFont.meta)
                    .foregroundStyle(accessoryColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            if changed {
                Circle()
                    .fill(TFColor.textPrimary)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(selected ? TFColor.bgSelected : .clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(title: title, accessory: accessory, changed: changed))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    nonisolated static func accessibilityLabel(title: String, accessory: String?, changed: Bool) -> String {
        [title, accessory, changed ? "Changed" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    private var titleColor: Color {
        guard dimmed else { return TFColor.textPrimary }
        return selected ? TFColor.textSecondarySelected : TFColor.textSecondary
    }

    private var accessoryColor: Color {
        switch (urgent, selected) {
        case (true, true): TFColor.statusOverdueSelected
        case (true, false): TFColor.statusOverdue
        case (false, true): TFColor.textSecondarySelected
        case (false, false): TFColor.textSecondary
        }
    }
}

/// 목록 섹션 머리 (Figma M1 `Section · Review`): 이름 + 개수, 둘 다 12 Regular 보조 색. 위 10 · 왼쪽 10 · 아래 4.
/// Done Today처럼 접는 섹션은 `disclosure`로 꺾쇠를 붙이고 눌러서 연다(아래 6).
/// 고정 머리로 쓸 때는 부르는 쪽이 목록 면 색(settings/sidebar)을 깐다.
public struct SectionHeader: View {
    public enum Disclosure: Sendable, Hashable {
        case collapsed, expanded
    }

    let title: String
    let count: Int
    let disclosure: Disclosure?
    let selected: Bool
    let action: (() -> Void)?

    public init(_ title: String, count: Int, disclosure: Disclosure? = nil, selected: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.count = count
        self.disclosure = disclosure
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(count)")
                .accessibilityValue(disclosure == .collapsed ? "Collapsed" : disclosure == .expanded ? "Expanded" : "")
                .accessibilityAddTraits(.isHeader)
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title), \(count)")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Text(title)
            Text("\(count)")
            if let disclosure {
                Image(systemName: disclosure == .collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 12, height: 12)
            }
        }
        .font(TFFont.meta)
        .foregroundStyle(selected ? TFColor.textSecondarySelected : TFColor.textSecondary)
        .lineLimit(1)
        .padding(.top, 10)
        .padding(.leading, 10)
        .padding(.bottom, disclosure == nil ? TFSpace.xs : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? TFColor.bgSelected : .clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// 접힌 섹션의 나머지 (Figma M1 `More · 2 more`): "Show 2 More ⌄"(꺾쇠는 아래로), 높이 28, 왼쪽 10. 키보드(↩)와 VoiceOver로도 연다.
/// VoiceOver: "Show 2 more in Review"
public struct ShowMoreRow: View {
    let count: Int
    let section: String
    let selected: Bool
    let action: () -> Void

    public init(count: Int, section: String, selected: Bool = false, action: @escaping () -> Void) {
        self.count = count
        self.section = section
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: TFSpace.xs) {
                Text("Show \(count) More")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 12, height: 12)
            }
            .font(TFFont.meta)
            .foregroundStyle(selected ? TFColor.textSecondarySelected : TFColor.textSecondary)
            .lineLimit(1)
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(selected ? TFColor.bgSelected : .clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(count) more in \(section)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview("Mac list") {
    VStack(spacing: 0) {
        SectionHeader("Review", count: 4)
        MacListRow(title: "제안서 v2 보내기", accessory: "Approve Send")
        MacListRow(title: "가입 단계 축소", accessory: "Resolve Conflict", changed: true)
        ShowMoreRow(count: 2, section: "Review") {}
        SectionHeader("In Progress", count: 5)
        MacListRow(title: "금요일 고객 데모 준비 (새 온보딩, 결제 화면 포함)", accessory: "Fri", changed: true, selected: true)
        MacListRow(title: "온보딩 디자인 시안", accessory: "Today", urgent: true)
        MacListRow(title: "해외 파트너 요구사항을 반영한 다음 주 경영진 리뷰 발표 자료 정리", accessory: "Tue")
        MacListRow(title: "데모 환경 배포", accessory: "Today", urgent: true, selected: true)
        ShowMoreRow(count: 9, section: "To Do", selected: true) {}
        SectionHeader("Done Today", count: 6, disclosure: .collapsed) {}
        MacListRow(title: "주간 회의록 정리", dimmed: true)
    }
    .padding(8)
    .frame(width: 300)
    .background(TFColor.settingsSidebar)
}
