#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 상세 칸 (Figma M1 `Detail viewport`, bg/elevated, 안쪽 위 18 · 좌우 24): U1은 임시 상세다.
/// 제목(자르지 않음) · 기한 · Review 이유 · 원문(`EvidenceDigest`의 근거 줄, 종이 위 인용).
/// 갈래(`You` · `Waiting on` · `Taskforce` · `Done when`)는 U5 · U2 Mac · U6a가 `lanes` 자리에 끼운다.
/// 저장본 행(오프라인)은 저장된 제목 · 기한만 있다.
struct LauncherDetailPane: View {
    @Bindable var model: LauncherModel

    /// 아래에 더 있는지 (아래 흐림)
    @State private var hasMoreBelow = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let target = model.detailTarget {
                    header(title: target.action.title, due: target.group == .doneToday ? nil : target.action.dueDate,
                           reason: target.group == .review ? ConfirmReasonText.label(target.action.confirmReasons) : nil)
                    // 갈래 자리 (U5 · U2 Mac · U6a)
                    sources(target.action.id)
                } else if let row = model.detailSavedRow {
                    header(title: row.task.title, due: row.task.status == .doneToday ? nil : row.task.dueDate, reason: nil)
                }
            }
            .padding(.horizontal, TFSpace.xl)
            .padding(.top, 18)
            .padding(.bottom, TFSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
        } action: { _, more in
            hasMoreBelow = more
        }
        .background(TFColor.bgElevated)
        .scrollEdgeFade(TFColor.bgElevated, isActive: hasMoreBelow)
    }

    private var today: LocalDate { DueDateFormat.today() }

    /// 제목 20 semibold (자르지 않음) + 기한 · 확인 이유 12
    private func header(title: String, due: LocalDate?, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TFFont.title)
                .foregroundStyle(TFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if due != nil || reason != nil {
                VStack(alignment: .leading, spacing: TFSpace.xs) {
                    if let due {
                        Text("Due \(DueText.short(due, today: today))")
                            .foregroundStyle(DueText.isUrgent(due: due, reasons: [], today: today) ? TFColor.statusOverdue : TFColor.textSecondary)
                    }
                    if let reason {
                        Text(reason).foregroundStyle(TFColor.textSecondary)
                    }
                }
                .font(TFFont.meta)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sources(_ id: UUID) -> some View {
        if let digest = model.now?.evidence[id] {
            if !digest.isEmpty {
                VStack(alignment: .leading, spacing: TFSpace.sm) {
                    Text(digest.lines.count == 1 ? "Source" : "Sources")
                        .font(TFFont.footnoteEmphasis)
                        .foregroundStyle(TFColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    // 가장 최근 근거(지금 상태를 만든 말)가 위
                    ForEach(digest.lines.reversed()) { line in
                        SourceSlip(line: line) { url in model.open(url) }
                    }
                }
            }
        } else if model.now?.evidenceFailed.contains(id) == true {
            Text("Couldn't load sources.")
                .font(TFFont.meta)
                .foregroundStyle(TFColor.textSecondary)
        }
    }
}

/// 원문 슬립 (Figma Source slip 158:3878): 종이 면 위 인용(3줄까지) + 서비스 로고 · 원문 이름 · 시점. 누르면 원문을 연다
struct SourceSlip: View {
    let line: EvidenceLine
    let onOpen: (URL) -> Void

    var body: some View {
        let removed = RemovedQuote.isRemoved(line.quote)
        VStack(alignment: .leading, spacing: 6) {
            Text(removed ? RemovedQuote.label : "“\(line.quote)”")
                .font(TFFont.footnote)
                .foregroundStyle(removed ? TFColor.sourceMeta : TFColor.sourceText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: TFSpace.sm) {
                SourceIcon(line.service, size: .s)
                if let title = line.displayTitle, !title.isEmpty {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let date = line.displayDate {
                    Text(WhenText.label(date))
                        .fixedSize()
                }
            }
            .font(TFFont.meta)
            .foregroundStyle(TFColor.sourceMeta)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(TFColor.sourcePaper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = line.externalURL { onOpen(url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(line.externalURL == nil ? [] : .isLink)
    }
}
#endif
