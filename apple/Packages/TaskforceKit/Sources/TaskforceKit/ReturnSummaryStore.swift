import Foundation
import Observation

/// Clear 한 번의 결과. **성공은 서버가 200으로 답한 뒤에만** 말한다 (낙관적 표시 없음). Clear는 읽음 처리일 뿐이다:
/// 어느 결과든 결정 · Action · run · 정책 · 승인은 바뀌지 않는다
public enum ReturnSummaryClearResult: Equatable, Sendable {
    /// 200: 서버가 읽음 처리했다 (`applied == false`는 쓸 것이 없었다 — 재시도 · 다른 기기가 먼저 — 그것도 성공이다)
    case cleared(applied: Bool)
    /// 409: 조회한 뒤 그 범위의 사건이 달라졌다. 아무것도 읽음 처리하지 않았다 → 자동 재전송 없이 다시 조회했다
    case conflict
    /// 400: 모양이 틀린 · 미래 · 남의 · 옛 커서. 아무것도 읽음 처리하지 않았다 → 자동 재전송 없이 다시 조회했다
    case invalid
    /// 404: 이 서버는 아직 이 기능이 없다 (gate 꺼짐). 줄을 지웠다
    case unavailable
    /// 요청이 거절됐다 (그 밖의 4xx). 아무것도 바뀌지 않았다
    case failed
    /// 응답을 받지 못했거나 서버 오류 · 읽지 못한 응답: 서버가 읽음 처리했는지 **모른다**. 성공을 말하지 않고, 자동 재전송 없이 다시 조회해 지금 상태를 보였다
    case unconfirmed
    /// 보내지 않음: 계정이 바뀌었거나 · 화면이 더는 그 소유가 아니거나 · 커서가 더는 사용자가 본 것이 아니다
    case ignored
}

/// 첫 정상 표시 확정(기준점) 한 번의 결과. 성공은 서버 200뿐이다 (`already_initialized`도 성공이다: 이미 기준점이 있다)
public enum ReturnSummaryBaselineResult: Equatable, Sendable {
    /// 200 `initialized`: 이 요청이 기준점을 만들었다 → 조회로 확인했다
    case initialized
    /// 200 `already_initialized`: 이미 기준점이 있거나 Clear한 적이 있다 (두 기기 · 응답 유실 재시도 · 늦은 확정). 아무것도 쓰지 않았다 → 조회로 확인했다
    case alreadyInitialized
    /// 409: 확인과 표시 사이에 기준점 범위가 달라졌다. 아무것도 쓰지 않았다. 자동으로 다시 보내지 않는다 (다음 정상 표시의 새 토큰으로)
    case conflict
    /// 400: 모양이 틀린 · 남의 · 미래 · 옛 형식 토큰. 아무것도 쓰지 않았다
    case invalid
    /// 404: 이 서버는 아직 이 기능이 없다 (gate 꺼짐). 줄을 지웠다
    case unavailable
    /// 요청이 거절됐다 (그 밖의 4xx). 아무것도 바뀌지 않았다
    case failed
    /// 응답을 받지 못했거나 서버 오류 · 읽지 못한 응답: 서버가 기준점을 만들었는지 **모른다**. 성공을 말하지 않는다. 자동 재전송 없음
    case unconfirmed
    /// 보내지 않음: 계정이 바뀌었거나 · 화면(방문)이 더는 그 소유가 아니거나 · 그 응답이 더는 지금 보이는 응답이 아니다
    case ignored
}

/// 복귀 요약 저장소 (C3). All work 맨 위 카드가 보일 것을 서버에서 읽고, 사용자가 누른 Clear(읽음 처리) 하나를 보낸다.
/// - **읽기**: `GET /api/v2/return-summary`. 읽기 순번으로 **마지막에 시작한 읽기만** 반영한다 (늦게 끝난 옛 읽기가 새 상태를 되돌리지 못한다).
///   404(gate 꺼짐)는 줄을 지우고 아무 말도 하지 않는다. 읽지 못하면 받은 줄은 두되 **오래됨**으로 표시하고 Clear를 숨긴다 (S3b `WorkContextStore`와 같은 방식).
///   서버 응답이 완전하다고 말할 때만 "비어 있음"을 안다 (`ReturnSummaryResponse.isEmpty`): 일부 실패 · 잘림 · 모르는 값은 비어 있는 것이 아니다
/// - **Clear**: S4 `ReviewDesk`와 같은 두 단계. `beginClear`가 **받는 동기 경계**에서 계정 token · 커서 · 소유 번호를 잡고 진행 표시를 올리고,
///   `sendClear`가 **보내기 직전**에 다시 본다 (계정 token 그대로 · 소유 번호가 살아 있음 · 호출한 쪽의 화면 소유권 · 지금 보이는 줄의 커서가 그 커서). 하나라도 어긋나면 쓰기 0이다.
///   모든 await 뒤에 다시 본다. 서버로 나간 요청은 취소하지 않는다 (서버가 받았는지 모르는 요청을 버리지 않는다)
/// - 성공은 서버 200뿐이다. 409 · 400 · 응답 유실은 **같은 커서를 자동으로 다시 보내지 않고** 다시 조회한다 (새 커서로 사용자가 다시 누른다).
///   이미 쓴 커서는 새 조회가 오기 전까지 다시 받지 않는다 (`cursorSpent`)
/// - 계정 경계: `AccountScope`에 붙어 계정이 떠나면(로그아웃 · 다른 계정 · 같은 UUID 재로그인) 모두 비우고 늦은 응답을 버린다 (화면이 떠 있는지와 무관).
///   옛 요청의 정리는 자기 소유 번호일 때만 진행 표시를 푼다. 새 영구 캐시는 없다: 모두 이 객체의 메모리다
/// - 복귀 요약은 읽기와 읽음 처리뿐이다: 이 저장소가 서버에서 부르는 것은 게이트웨이의 두 호출뿐이고, 결정 · 승인 · 실행 · 정책을 부르지 않는다 (ARCH06/07)
@MainActor
@Observable
public final class ReturnSummaryStore {
    /// 마지막으로 받은 응답 (Clear 뒤 · 새 방문마다 서버가 다시 준 것으로 바뀐다)
    public private(set) var summary: ReturnSummaryResponse?
    /// 받은 뒤 다시 읽지 못했다: 줄은 두되 오래된 것이다 (Clear를 숨긴다)
    public private(set) var isStale = false
    /// 한 번도 받지 못한 채 읽기가 실패했다
    public private(set) var readFailed = false
    /// 서버 gate가 꺼져 있다 (404): 이 서버는 아직 이 기능이 없다
    public private(set) var featureOff = false
    /// Clear를 보내는 중 (후속 조회까지)
    public private(set) var isClearing = false
    /// Clear 뒤 안내 한 줄 (충돌 · 거절). 새 방문(`refresh`)이 지운다
    public private(set) var message: String?
    /// 마지막으로 보낸 Clear가 쓴 커서: 새 조회가 오기 전에는 같은 커서를 다시 받지 않는다
    public private(set) var cursorSpent = false

    @ObservationIgnored private let gateway: any ReturnSummaryGateway
    @ObservationIgnored private let scope: AccountScope
    /// 읽기 순번: 읽기를 시작할 때 하나씩 올린다. **마지막에 시작한 읽기만** 반영한다
    @ObservationIgnored private var readSequence = 0
    /// 진행 중인 Clear의 소유 번호 (한 번에 하나). 끝날 때 자기 번호일 때만 진행 표시를 푼다: 세션이 바뀐 뒤 새 요청의 진행 표시를 옛 요청이 지우지 않게 한다
    @ObservationIgnored private var clearOwner: Int?
    @ObservationIgnored private var clearCounter = 0
    /// 지금 보이는 응답의 번호: 읽기가 반영되거나(새 응답) 기능 꺼짐으로 지우거나 계정이 떠날 때마다 오른다. 첫 정상 표시 확정이 "그 응답이 아직 보이는가"를 가린다
    @ObservationIgnored private var displaySerial = 0
    /// 이 응답(번호)으로 확정을 이미 받았다 (한 응답에 시도는 한 번)
    @ObservationIgnored private var baselineAttempted = -1
    @ObservationIgnored private var baselineOwner: Int?
    @ObservationIgnored private var baselineCounter = 0

    public init(gateway: any ReturnSummaryGateway, scope: AccountScope) {
        self.gateway = gateway
        self.scope = scope
        scope.onLeft { [weak self] in self?.reset() }
    }

    /// 계정이 떠남: 모두 비운다 (읽는 중 · 보내는 중인 요청의 늦은 결과는 `scope.isCurrent`가 버린다)
    public func reset() {
        readSequence += 1
        displaySerial += 1
        clearOwner = nil
        baselineOwner = nil
        isConfirmingBaseline = false
        summary = nil
        isStale = false
        readFailed = false
        featureOff = false
        isClearing = false
        message = nil
        cursorSpent = false
    }

    // MARK: 보이는 것

    /// 화면이 그릴 것. 아무것도 보일 것이 없으면 nil (읽기 전 · 기능 꺼짐 · 완전히 비어 있음)
    public func content(now: Date = Date(), timeZone: TimeZone = .current, canOpen: (UUID) -> Bool = { _ in true }) -> ReturnSummaryContent? {
        ReturnSummaryPresentation.make(
            summary: summary, isStale: isStale, readFailed: readFailed, cursorSpent: cursorSpent, isClearing: isClearing, message: message,
            now: now, timeZone: timeZone, canOpen: canOpen
        )
    }

    // MARK: 읽기

    /// 새 방문(패널 열기 · 로그인 · Try again): 안내를 거두고 서버의 지금 상태를 읽는다
    public func refresh() async {
        guard let token = scope.token else { return }
        message = nil
        await read(for: token)
    }

    private func read(for token: AccountScope.Token) async {
        readSequence += 1
        let sequence = readSequence
        do {
            let response = try await gateway.returnSummary()
            guard scope.isCurrent(token), sequence == readSequence else { return }
            summary = response
            isStale = false
            readFailed = false
            featureOff = false
            cursorSpent = false
            displaySerial += 1
            // 이 응답이 지금 화면에 보일 수 있게 됐다 (동기): 첫 정상 표시 확정이 있으면 셸이 이 자리에서 받는다
            onDisplayed?()
        } catch {
            guard scope.isCurrent(token), sequence == readSequence, !(error is CancellationError) else { return }
            if let api = error as? APIError, api.isFeatureOff {
                // 이 서버는 아직 이 기능이 없다: 전에 받은 줄도 거둔다 (오류가 아니다)
                summary = nil
                featureOff = true
                readFailed = false
                isStale = false
                cursorSpent = false
                displaySerial += 1
            } else if summary != nil {
                isStale = true
            } else {
                readFailed = true
            }
        }
    }

    // MARK: 첫 정상 표시 확정 (C: 기준점)

    /// 정상 표시가 된 **그때** 동기 경계에서 잡은 것: 그때의 계정 token · 서버가 준 토큰 · 그 응답의 표시 번호 · 소유 번호
    public struct BaselineTicket: Sendable {
        let token: AccountScope.Token
        let initToken: String
        let serial: Int
        let owner: Int
    }

    /// 첫 정상 표시 확정을 보내는 중 (한 번에 하나)
    public private(set) var isConfirmingBaseline = false
    /// 읽기가 반영될 때마다 (그 응답이 지금 화면에 보일 수 있게 됐다) 동기로 부른다: 셸이 **표시 시점**에 확정을 받는 곳 (`EdgeShellModel.considerSummaryBaseline`)
    @ObservationIgnored public var onDisplayed: (@MainActor () -> Void)?

    /// 첫 정상 표시 확정을 **받는다** (표시 시점, 동기 경계). 정상 표시일 때만 — 서버가 `init_token`을 준 첫 사용(`never_cleared`) 응답이고, 변화 원천을 읽었고(ok · 정상 잘림),
    /// 해석 못 한 변화가 보이지 않고, 오래된 줄이 아니고, 같은 계정이고, Clear를 보내는 중이 아니고, 이 응답으로 아직 받은 적이 없을 때. 받는 순간 이 응답의 시도를 소비한다 (같은 응답으로 다시 받지 않는다:
    /// 보내지 못했거나 409 · 응답 유실이어도 다음 정상 표시 — 새 조회의 새 토큰 — 에서만).
    /// 빈 첫 화면(완전하고 줄이 없음)도 정상 표시다. 확정은 읽음 표시일 뿐이다: 결정 · 완료가 아니다
    public func beginBaseline() -> BaselineTicket? {
        guard let token = scope.token, let summary, let initToken = summary.initToken, summary.baseline == .neverCleared,
              !isStale, !isClearing, !isConfirmingBaseline, baselineAttempted != displaySerial,
              summary.sources.changes == .ok || summary.sources.changes == .truncated,
              !summary.hasUnreadableChangeStatus, !summary.hasUninterpretableChange else { return nil }
        baselineAttempted = displaySerial
        baselineCounter += 1
        let owner = baselineCounter
        baselineOwner = owner
        isConfirmingBaseline = true
        return BaselineTicket(token: token, initToken: initToken, serial: displaySerial, owner: owner)
    }

    /// 받아 둔 확정을 보낸다. **보내기 직전에** 다시 본다: 계정 token이 그대로(같은 UUID 재로그인 · 다른 계정이면 달라진다, 같은 계정의 토큰 갱신은 그대로)이고, 소유 번호가 살아 있고(`reset()`이 비우면 죽는다),
    /// 지금 보이는 응답이 그 응답(더 새 읽기가 반영되지 않았고 토큰도 그대로)이고, 오래된 줄이 아니고, 호출한 쪽의 `isStillValid`(패널 · All work 방문)가 참일 때만 보낸다. 하나라도 어긋나면 쓰기 0 · `.ignored`다.
    /// 이미 나간 요청은 취소하지 않는다: 정직한 결과를 돌려준다. 성공(200 `initialized` · `already_initialized`)은 조회로 확인한다. 409 · 400 · 응답 유실 · 거절은 **자동으로 다시 보내지 않고** 다시 조회하지도 않는다
    /// (다음 정상 표시가 새 토큰을 준다). 모든 await 뒤에 다시 본다
    @discardableResult
    public func sendBaseline(_ ticket: BaselineTicket, isStillValid: () -> Bool) async -> ReturnSummaryBaselineResult {
        // 세션이 바뀌면 `reset()`이 진행 표시를 비우고 새 세션이 새 확정을 잡을 수 있다: 이 요청이 잡은 것일 때만 푼다
        defer {
            if baselineOwner == ticket.owner {
                baselineOwner = nil
                isConfirmingBaseline = false
            }
        }
        guard scope.isCurrent(ticket.token), baselineOwner == ticket.owner, displaySerial == ticket.serial, summary?.initToken == ticket.initToken,
              !isStale, isStillValid() else { return .ignored }
        var responded = false
        let result: ReturnSummaryBaselineResult
        do {
            let response = try await gateway.confirmReturnSummaryBaseline(initToken: ticket.initToken)
            guard ownsBaseline(ticket) else { return .ignored }
            responded = true
            switch response.status {
            case .initialized: result = .initialized
            case .alreadyInitialized: result = .alreadyInitialized
            case .unknown: result = .unconfirmed
            }
        } catch {
            guard ownsBaseline(ticket) else { return .ignored }
            result = baselineFailure(error)
        }
        if result == .unavailable {
            // 이 서버는 아직 이 기능이 없다: 전에 받은 줄도 거둔다 (오류가 아니다)
            summary = nil
            featureOff = true
            isStale = false
            readFailed = false
            cursorSpent = false
            displaySerial += 1
        }
        if responded {
            // 200을 받았다 (성공 · 모르는 status 모두): 서버의 지금 상태를 다시 읽는다 (기준점이 생겼으면 응답의 baseline이 바뀌고 토큰은 없어진다)
            await read(for: ticket.token)
            guard ownsBaseline(ticket) else { return .ignored }
        }
        return result
    }

    private func ownsBaseline(_ ticket: BaselineTicket) -> Bool {
        scope.isCurrent(ticket.token) && baselineOwner == ticket.owner
    }

    /// 보낸 확정이 던진 오류를 결과로. 사용자에게 보이는 안내는 없다 (기준점은 화면에 나타나지 않는 읽음 표시다)
    private func baselineFailure(_ error: Error) -> ReturnSummaryBaselineResult {
        guard let api = error as? APIError else { return .unconfirmed }
        if api.isFeatureOff { return .unavailable }
        if api.isConflict { return .conflict }
        if case .server(400, _, _) = api { return .invalid }
        if let status = api.status, (400..<500).contains(status) { return .failed }
        // 응답을 받지 못했다(전송 오류) · 서버 오류 · 읽지 못한 응답 · 로그인 세션 없음: 서버가 기준점을 만들었는지 모른다
        return .unconfirmed
    }

    // MARK: Clear

    /// 받는 동기 경계에서 잡은 선택: 그때의 계정 token · 사용자가 본 커서 · 소유 번호
    public struct ClearTicket: Sendable {
        let token: AccountScope.Token
        let cursor: String
        let owner: Int
    }

    /// Clear를 **받는다** (클릭, 동기 경계): 계정 token · 커서를 잡고 진행 표시를 올린다.
    /// 서버 커서가 없거나 · 읽음 처리할 변화가 보이지 않거나 · 다시 읽지 못한 줄이거나 · 이미 쓴 커서이거나 · 이미 보내는 중이면 nil이다
    public func beginClear() -> ClearTicket? {
        guard let token = scope.token, !isClearing, let summary, let cursor = summary.cursor,
              ReturnSummaryPresentation.canClear(summary, isStale: isStale, cursorSpent: cursorSpent) else { return nil }
        clearCounter += 1
        let owner = clearCounter
        clearOwner = owner
        isClearing = true
        message = nil
        return ClearTicket(token: token, cursor: cursor, owner: owner)
    }

    /// 받아 둔 Clear를 보낸다. **보내기 직전에** 다시 본다: 계정 token이 그대로(같은 UUID 재로그인 · 다른 계정이면 달라진다, 같은 계정의 토큰 갱신은 그대로)이고,
    /// 소유 번호가 살아 있고(`reset()`이 비우면 죽는다), 지금 보이는 줄의 커서가 사용자가 본 그 커서이고, 호출한 쪽의 `isStillValid`(패널 · All work 화면)가 참일 때만 보낸다.
    /// 하나라도 어긋나면 쓰기 0 · `.ignored`다 (자기 번호일 때만 진행 표시를 거둔다). 이미 나간 요청은 취소하지 않는다
    @discardableResult
    public func sendClear(_ ticket: ClearTicket, isStillValid: () -> Bool) async -> ReturnSummaryClearResult {
        // 세션이 바뀌면 `reset()`이 진행 표시를 비우고 새 세션이 새 Clear를 잡을 수 있다: 이 요청이 잡은 것일 때만 푼다
        defer {
            if clearOwner == ticket.owner {
                clearOwner = nil
                isClearing = false
            }
        }
        guard scope.isCurrent(ticket.token), clearOwner == ticket.owner, summary?.cursor == ticket.cursor, !isStale, isStillValid() else { return .ignored }
        let result: ReturnSummaryClearResult
        do {
            let response = try await gateway.clearReturnSummary(cursor: ticket.cursor)
            guard owns(ticket) else { return .ignored }
            result = .cleared(applied: response.applied)
        } catch {
            guard owns(ticket) else { return .ignored }
            result = failure(error)
        }
        switch result {
        case .unavailable:
            summary = nil
            featureOff = true
            isStale = false
            readFailed = false
            cursorSpent = false
        case .failed:
            // 아무것도 바뀌지 않았다: 같은 줄 · 같은 커서 그대로, 사용자가 다시 누를 수 있다
            break
        case .cleared, .conflict, .invalid, .unconfirmed:
            // 이 커서는 썼다: 새 조회가 오기 전에는 다시 받지 않는다 (200 · 409 · 400 · 응답 유실 모두).
            // 성공은 조회로 확인하고, 그 밖에는 자동으로 다시 보내지 않고 지금 상태를 읽는다 (모든 await 뒤 다시 본다)
            cursorSpent = true
            await read(for: ticket.token)
            guard owns(ticket) else { return .ignored }
        case .ignored:
            break
        }
        return result
    }

    private func owns(_ ticket: ClearTicket) -> Bool {
        scope.isCurrent(ticket.token) && clearOwner == ticket.owner
    }

    /// 보낸 Clear가 던진 오류를 결과로 (안내 문구는 앱의 기존 오류 문구)
    private func failure(_ error: Error) -> ReturnSummaryClearResult {
        guard let api = error as? APIError else { return .unconfirmed }
        if api.isFeatureOff { return .unavailable }
        if api.isConflict {
            message = api.userMessage
            return .conflict
        }
        if case .server(400, _, _) = api {
            message = api.userMessage
            return .invalid
        }
        if let status = api.status, (400..<500).contains(status) {
            // 서버가 요청을 거절했다 (아무것도 읽음 처리하지 않았다)
            message = api.userMessage
            return .failed
        }
        // 응답을 받지 못했다(전송 오류) · 서버 오류 · 읽지 못한 응답 · 로그인 세션 없음: 서버가 처리했는지 모른다
        return .unconfirmed
    }
}
