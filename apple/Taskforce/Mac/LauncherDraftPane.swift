#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 초안 상세 칸 (Figma 없음, 열린 질문 5): 초안 제목 + `AI draft · 14:20` + 고를 수 있는 본문 (`DraftBody`).
/// 본문을 지웠으면(90일) 그 사실을 적는다. 액션 바 `Copy ⌘C`.
struct LauncherDraftPane: View {
    let artifact: Artifact

    @State private var hasMoreBelow = false

    var body: some View {
        ScrollView {
            DraftBody(artifact, detail: "AI draft · \(LauncherLaneText.clock(artifact.createdAt))")
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
}
#endif
