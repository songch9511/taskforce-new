#if os(macOS)
import Foundation

// Assistant 창이 이 Mac의 런타임에서 읽는 두 가지 (OA D4a-1): 잘린 답의 전문(View full)과 이 Mac의 bridge id(세션 알약을 이 Mac의 세션에만 보인다).
// 읽기만 한다: 원장 표 · 런타임 상태를 바꾸지 않는다.

extension BridgeRuntime {
    /// 서버 열쇠(`external_event_id`)로 이 Mac 원장의 잘린 글 전문을 찾는다 (없으면 nil)
    public func fullText(forServerKey key: String) async -> String? {
        (try? await ledger.fullText(forServerKey: key)) ?? nil
    }

    /// 이 Mac이 서버에 등록해 받은 bridge id (등록 전 · 읽을 수 없는 값이면 nil)
    public func localBridgeID() async -> UUID? {
        guard let raw = (try? await ledger.meta())?.bridgeID else { return nil }
        return UUID(uuidString: raw)
    }
}
#endif
