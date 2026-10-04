#if os(iOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// iPhone 초안 화면 (Figma 프레임 없음 — U2 Mac 계획 열린 질문 5): 상세 갈래의 `View Draft` · 초안 링크(`taskforce://artifacts/<id>`)로 연다.
/// 초안 제목 + `AI draft · 14:20` + 고를 수 있는 본문(`DraftBody`), 오른쪽 위 `Copy`(제목 + 본문). 본문을 지운 초안(90일)은 Copy가 없다.
/// 본문은 사용자 글이다: 화면에만 두고 로그 · 디스크에 남기지 않는다 (Copy는 사용자가 누를 때만 클립보드로).
struct DraftView: View {
    let artifact: Artifact

    /// Copy를 누를 때마다 (햅틱)
    @State private var copies = 0

    var body: some View {
        ScrollView {
            DraftBody(artifact, detail: "AI draft · \(RunLaneText.clock(artifact.createdAt))")
                .padding(.horizontal, TFSpace.lg)
                .padding(.top, TFSpace.sm)
                .padding(.bottom, TFSpace.xl)
        }
        .background(TFColor.bgCanvas)
        .navigationTitle("Draft")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !artifact.isPurged {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Copy") {
                        Clipboard.copy("\(artifact.title)\n\n\(artifact.body)")
                        copies += 1
                        AccessibilityNotification.Announcement("Copied").post()
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: copies)
    }
}
#endif
