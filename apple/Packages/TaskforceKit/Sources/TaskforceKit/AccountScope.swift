import Foundation

/// 계정 경계 (S1 `ProfileDraft` 방식을 대화 · 기억 저장소에 재사용): 앱이 시작할 때 세션에 한 번 붙는다.
/// 화면(패널 · 설정 창)이 떠 있는지와 상관없이, 계정이 이 기기를 떠나면(로그아웃 · 세션 만료 · 계정 삭제 · 다른 계정 ·
/// 같은 사용자의 재로그인) `epoch`가 오르고 붙어 있는 저장소가 초안 · 캐시 · 대기 전송을 비운다.
/// 저장소는 일을 시작할 때 `token`을 잡고, 응답이 오거나 다시 보내기 직전에 `isCurrent`로 같은 계정 · 같은 세션인지 다시 본다.
/// 토큰 갱신처럼 같은 계정이면 `epoch`가 그대로라 데이터를 잃지 않는다.
@MainActor
public final class AccountScope {
    /// 일을 시작한 계정과 세션 세대
    public struct Token: Equatable, Sendable {
        public let userID: UUID
        public let epoch: Int
    }

    public private(set) var epoch = 0
    private var currentAccount: (@MainActor () -> UUID?)?
    private var leaveHandlers: [@MainActor () -> Void] = []

    public init() {}

    /// 지금 로그인한 계정을 직접 알려 주는 판 (테스트 · 견본)
    public init(currentAccount: @escaping @MainActor () -> UUID?) {
        self.currentAccount = currentAccount
    }

    /// 세션에 붙는다 (앱이 실행할 때 한 번, `session.start()` 전에). `account`가 없으면 세션이 로그인 중인 계정이다.
    /// 견본은 로그인 없이 견본 계정을 넘긴다
    public func bind(to session: SessionStore, account: (@MainActor () -> UUID?)? = nil) {
        guard currentAccount == nil else { return }
        currentAccount = account ?? { [weak session] in
            if case .signedIn(let userID, _)? = session?.state { userID } else { nil }
        }
        session.onSignedOut { [weak self] _ in self?.accountLeft() }
    }

    /// 계정이 떠날 때 부를 정리 (저장소의 `reset`)
    public func onLeft(_ handler: @escaping @MainActor () -> Void) {
        leaveHandlers.append(handler)
    }

    /// 계정이 이 기기를 떠남: 세대를 올리고 정리를 부른다. 그 전에 시작한 일의 늦은 응답은 `isCurrent`가 막는다
    public func accountLeft() {
        epoch += 1
        for handler in leaveHandlers { handler() }
    }

    /// 지금 로그인한 계정과 세대 (로그아웃 · 읽는 중이면 nil)
    public var token: Token? {
        currentAccount?().map { Token(userID: $0, epoch: epoch) }
    }

    /// 일을 시작한 뒤에도 같은 계정이고 같은 세션인가
    public func isCurrent(_ token: Token) -> Bool {
        token.epoch == epoch && currentAccount?() == token.userID
    }
}
