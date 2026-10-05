#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Run with AI 상세 칸 (Figma M8 185:2332 `Detail content`): 제목 `Run with AI` + 할 일 제목, 폼 Goal · Use · Output · Mode · Limit · Cost.
/// U2에서 숨기는 것 (U2 Mac 계획 PR3 표): Use `+`(자료 고르기 API 없음) · Done when(U5) · Mode `Change`(U6b).
/// Goal은 사용자 글이라 메모리에만 두고, 런처를 닫을 때까지 할 일별로 남는다 (`LauncherModel.goal`). Start는 액션 바 `Start ⌘↩`.
struct LauncherRunPane: View {
    @Bindable var model: LauncherModel
    let target: LauncherModel.Target

    @FocusState private var goalFocused: Bool
    /// 아래에 더 있는지 (아래 흐림)
    @State private var hasMoreBelow = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run with AI")
                        .font(TFFont.title)
                        .foregroundStyle(TFColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(target.action.title)
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: TFSpace.md) {
                    FormField("Goal", isInput: true) {
                        GrowingTextField("Goal", text: $model.goal, prompt: "What should the draft cover?", isFocused: $goalFocused)
                    }
                    // 보낼 수 있는 원문이 없으면 (Slack뿐 · 근거 없음) 줄을 두지 않는다
                    if let sources = model.draftSources, !sources.isEmpty {
                        FormField("Use") {
                            ChipFlow(sources)
                                // 라벨을 첫 줄 칩 글자에 맞춘다 (칩 안쪽 위 3 + 12pt 글자의 기준선)
                                .alignmentGuide(.firstTextBaseline) { _ in 15 }
                        }
                    }
                    FormField("Output") { FormValue("Draft in Taskforce", detail: "Nothing is sent or shared") }
                    FormField("Mode") { FormValue("Manual", detail: "Asks before any change outside Taskforce") }
                    FormField("Limit") { FormValue("This task only", detail: "Stops when the draft is ready") }
                    FormField("Cost") { FormValue("Uses credits", detail: costDetail) }
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
        // 처음 포커스는 Goal
        .task(id: target.action.id) { goalFocused = true }
    }

    /// 잔액이 초안 한 건의 예약보다 적으면 (서버는 시작을 받고 크레딧이 들어오면 이어 간다, 열린 질문 13). 문구는 후보
    private var costDetail: String? {
        if case .disabled(.notAccepting) = model.runAvailability(for: target) {
            return "New AI drafts are temporarily unavailable."
        }
        return model.runs?.summary?.isBelowDraftEstimate == true ? "Not enough credits. Starts when credits are added." : nil
    }
}
#endif
