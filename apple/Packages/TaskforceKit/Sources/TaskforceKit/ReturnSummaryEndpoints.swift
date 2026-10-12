import Foundation

// 복귀 요약 읽기 · Clear (`/api/v2`, 서버 C3 head `6cfd382`, 인증은 Bearer). gate `REVIEW_V2_ENABLED`가 꺼진 서버는 두 경로 모두 404
// `{"error":{"code":"not_found","message":"없는 경로입니다."}}`다 (`APIError.isFeatureOff`: 이 서버는 아직 이 기능이 없다 — 오류가 아니다).
// Clear는 읽음 처리일 뿐이다: 결정 · Action · run · 정책 · 승인을 바꾸지 않는다. 409(조회한 뒤 범위가 달라졌다) · 400(모양이 틀린/옛/남의 커서)은
// 아무것도 읽음 처리하지 않았다는 뜻이고, 앱은 **자동으로 다시 보내지 않고** 다시 조회한다 (`ReturnSummaryStore`).

extension APIClient {
    /// 복귀 요약: 작업별 변화 · 필요한 결정 · Next 토큰 + Clear 커서. 서버는 문구를 만들지 않는다
    public func returnSummary() async throws -> ReturnSummaryResponse {
        try await send(.get, "return-summary", version: .v2)
    }

    /// 읽음 처리. `cursor`는 조회가 준 글자 **그대로**다 (열지 않고, 시각으로 바꾸지 않고, 클라이언트 시각을 더하지 않는다).
    /// 200 `applied == false`도 성공이다. 409 · 400 = 아무것도 읽음 처리하지 않았다, 404 = 이 서버는 아직 이 기능이 없다
    public func clearReturnSummary(cursor: String) async throws -> ReturnSummaryClearResponse {
        try await send(.post, "return-summary/clear", body: ReturnSummaryClearRequest(cursor: cursor), version: .v2)
    }
}
