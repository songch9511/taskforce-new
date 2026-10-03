import Foundation

/// 바뀜 점을 언제 지우고 `POST /actions/:id/seen`을 언제 보내나 (Figma 10차 사용자 결정, 2026-10-02).
/// - Mac 런처: 바뀐 행이 선택되어 상세가 보인 뒤 선택이 다른 행으로 옮겨 가면 (화살표로 지나가기만 해도) 한 번 보낸다. 선택이 없어져도(닫힘) 같다.
/// - iPhone: 그 할 일을 열면 바로 보낸다.
/// 보낸 할 일의 점은 바로 지운다. 보내기가 실패해도 다시 보내지 않는다: 다음 `/now`의 `changed`가 진실이다 (`refreshed()`).
public struct SeenTracker: Sendable, Hashable {
    /// 지금 선택된 바뀐 행 (아직 보내지 않음)
    public private(set) var viewing: UUID?
    /// 이번 `/now` 뒤에 보낸 할 일 (점을 지운다)
    public private(set) var sent: Set<UUID> = []

    public init() {}

    /// 점을 보일지: 서버가 바뀜이라 하고 이번 `/now` 뒤에 아직 보내지 않았으면
    public func showsDot(_ id: UUID, changed: Set<UUID>) -> Bool {
        changed.contains(id) && !sent.contains(id)
    }

    /// Mac 런처: 선택이 `id`로 옮겨 갔다 (nil = 선택 없음 · 런처 닫힘). 보낼 할 일(떠난 바뀐 행)이 있으면 돌려준다.
    public mutating func select(_ id: UUID?, changed: Set<UUID>) -> UUID? {
        guard id != viewing else { return nil }
        let leaving = viewing
        viewing = id.flatMap { showsDot($0, changed: changed) ? $0 : nil }
        guard let leaving else { return nil }
        sent.insert(leaving)
        return leaving
    }

    /// iPhone: 그 할 일을 열었다. 바뀐 할 일이면 지금 보낼 id를 돌려준다.
    public mutating func open(_ id: UUID, changed: Set<UUID>) -> UUID? {
        guard showsDot(id, changed: changed) else { return nil }
        sent.insert(id)
        if viewing == id { viewing = nil }
        return id
    }

    /// 새 `/now`를 받았다: 서버의 `changed`가 진실이라 보낸 기록을 비운다 (보내기가 실패했으면 점이 다시 보인다).
    /// 지금 선택된 행(`selected`, Mac 런처)이 이제 바뀜이면 떠날 때 보내고, 바뀜이 아니면 보내지 않는다.
    /// 보내기가 끝나기 전에 요청한 `/now`가 오면 점이 잠깐 다시 보일 수 있다 (서버는 바뀜일 때만 기록하므로 중복 기록은 없다).
    public mutating func refreshed(changed: Set<UUID>, selected: UUID? = nil) {
        sent = []
        viewing = selected.flatMap { changed.contains($0) ? $0 : nil }
    }

    /// 계정 전환 · 로그아웃
    public mutating func reset() {
        viewing = nil
        sent = []
    }
}
