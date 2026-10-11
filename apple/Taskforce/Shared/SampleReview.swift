#if DEBUG
import Foundation
import TaskforceKit

/// 디자인 비교 · 격리 확인용 가짜 답 서버 (Debug 빌드, `-TFSampleData`): Review 페이지의 Confirm · Dismiss 요청을 서버 없이 시나리오대로 돌려준다.
/// 실제 서버 · 계정 · AI 호출이 없는 렌더 fixture다. 요청이 몇 번 왔는지 세어 "반복 키 · 중복 클릭 → 1회"를 합성 조작으로 확인하는 데 쓴다.
/// `-TFSampleReview <이름>`: 시작 시나리오 (기본 apply)
@MainActor
final class SampleReviewServer {
    enum Scenario: String {
        /// 곧 받는다 (진행 표시가 잠깐 보이도록 짧은 지연)
        case apply
        /// 다른 기기가 먼저 바꿨다 (409)
        case conflict
        /// 이미 없다 (404)
        case notFound
        /// 응답을 잃었다 (서버가 처리했는지 알 수 없다)
        case loseResponse
        /// 끝나지 않는다 (`releaseHeld()`로 받는다)
        case hang
    }

    var scenario: Scenario
    private(set) var requests: [(id: UUID, answer: ReviewAnswer)] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    init(scenario: Scenario = SampleData.reviewScenario) {
        self.scenario = scenario
    }

    func handle(_ id: UUID, _ answer: ReviewAnswer) async -> ReviewWriteResult {
        requests.append((id, answer))
        switch scenario {
        case .apply:
            try? await Task.sleep(for: .milliseconds(250))
            return .applied
        case .conflict:
            try? await Task.sleep(for: .milliseconds(150))
            return .rejected(ReviewCopy.conflict)
        case .notFound:
            return .rejected(APIError.server(status: 404, code: .notFound, message: "").userMessage)
        case .loseResponse:
            try? await Task.sleep(for: .milliseconds(150))
            return .unverified
        case .hang:
            await withCheckedContinuation { held.append($0) }
            return .applied
        }
    }

    /// 센 요청을 비운다 (합성 조작이 단계마다 새로 센다)
    func clearRequests() { requests = [] }

    func releaseHeld() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}

extension SampleData {
    /// `-TFSampleReview <이름>`: Review 답 시작 시나리오 (기본 apply)
    static var reviewScenario: SampleReviewServer.Scenario {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TFSampleReview"), arguments.indices.contains(index + 1),
              let scenario = SampleReviewServer.Scenario(rawValue: arguments[index + 1]) else { return .apply }
        return scenario
    }
}

extension NowStore {
    /// 견본 Review 답을 가짜 서버로 보낸다
    func installSampleReview(_ server: SampleReviewServer) {
        sampleReview = { id, answer in await server.handle(id, answer) }
    }
}
#endif
