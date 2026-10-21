import Foundation

// 외부 세션 지표 (OA 외부 세션 PR1, 계약 10장 · 17장): `external_sessions_shown` — 레일의 "On this Mac" 목록이 행 1개 이상으로 보였을 때. `POST /api/v2/external-sessions/shown`
// (v1 `metric-events`는 동결이라 새 지표는 v2다). 값은 구간 문자열뿐이다 (글 · 수 0). 서버가 하루 한 번만 남긴다 (같은 날 두 번째도 204로 조용히 넘긴다).

/// 본문: `{ rows_bucket, held_bucket }` (서버 `externalSessionsShownRequestSchema`, strict)
struct ExternalSessionsShownRequest: Encodable, Equatable {
    let rowsBucket: String
    let heldBucket: String

    enum CodingKeys: String, CodingKey {
        case rowsBucket = "rows_bucket"
        case heldBucket = "held_bucket"
    }
}

/// 서버가 받는 구간 (`EXTERNAL_ROWS_BUCKETS` · `EXTERNAL_HELD_BUCKETS`)
public enum ExternalSessionsShownBuckets {
    public static let rows = ["1", "2-5", "6-15", "16+"]
    public static let held = ["0", "1-2", "3+"]
}

extension APIClient {
    /// 행 수와 돌고 있는 줄 수를 **구간으로만** 알린다. 서버는 204(본문 없음)로 답한다
    public func externalSessionsShown(rowsBucket: String, heldBucket: String) async throws {
        struct Empty: Decodable {}
        do {
            let _: Empty = try await send(.post, "external-sessions/shown", body: ExternalSessionsShownRequest(rowsBucket: rowsBucket, heldBucket: heldBucket), version: .v2)
        } catch APIError.decoding {
            // 204 본문 없음: 상태 코드가 2xx라 여기까지 온 것이다 (실패는 위에서 `APIError.server`로 던져진다)
        }
    }
}
