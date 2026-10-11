import Foundation
import Supabase

// 범위 멤버십 읽기 (RLS 본인 행, 새 서버 읽기 route 없음). 범위 목록은 `ChatReads.swift`의 `workContexts()`가 읽는다.
// 쓰기는 `APIClient`(`ContextEndpoints.swift`)로만 한다.

extension TaskforceReads {
    /// 지금 멤버 중 **할 일** 멤버: `removed_at is null` (사용자가 뺀 행은 가져오지 않는다), origin · confidence 그대로.
    /// 확인된 멤버 / 후보 구분은 읽은 뒤 `ContextMember.isConfirmed` · `isCandidate`로 한다 (서버 열을 앱이 따로 짐작하지 않는다)
    public func contextMembers() async throws -> [ContextMember] {
        var result: [ContextMember] = []
        var offset = 0
        while true {
            let page: [ContextMember] = try await rows(
                supabase.from("context_members").select(ContextMember.columns)
                    .eq("member_kind", value: "action").filter("removed_at", operator: "is", value: "null")
                    .order("created_at", ascending: true).order("id", ascending: true)
                    .range(from: offset, to: offset + Self.chatPageSize - 1)
            )
            result.append(contentsOf: page)
            guard page.count == Self.chatPageSize else { return result }
            offset += page.count
        }
    }
}
