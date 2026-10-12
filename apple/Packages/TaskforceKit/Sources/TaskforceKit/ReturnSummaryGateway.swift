import Foundation

/// 복귀 요약 저장소가 서버와 닿는 면 (읽기 · Clear 모두 서버 `/api/v2/return-summary`). 저장소는 이 프로토콜만 안다:
/// 테스트는 가짜로 붙잡기 · 실패 · 순서를 정확히 다룬다 (실제 연결은 `LiveReturnSummaryGateway`).
/// 이 면에는 결정 · 승인 · 실행 · 정책이 없다: 복귀 요약은 읽기이고 Clear는 읽음 처리일 뿐이다
public protocol ReturnSummaryGateway: Sendable {
    func returnSummary() async throws -> ReturnSummaryResponse
    func clearReturnSummary(cursor: String) async throws -> ReturnSummaryClearResponse
}

/// 실제 연결: `APIClient` (Bearer)
public struct LiveReturnSummaryGateway: ReturnSummaryGateway {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    public init(services: AppServices) {
        self.init(api: services.api)
    }

    public func returnSummary() async throws -> ReturnSummaryResponse { try await api.returnSummary() }

    public func clearReturnSummary(cursor: String) async throws -> ReturnSummaryClearResponse {
        try await api.clearReturnSummary(cursor: cursor)
    }
}
