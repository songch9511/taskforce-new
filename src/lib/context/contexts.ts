// 범위(work_contexts, 아키텍처 5.4)의 순수 규칙. 범위는 어떤 gate · 전이 · 판정에도 입력이 아니다(I14): 멤버십을 바꿔도 실행 권한은 바뀌지 않는다(D-13).
// 멤버십 origin: user(사용자가 정함, 자동 규칙이 덮지 않는다) · auto(코드 규칙) · inferred(모델 후보, confidence 필수, 묶음 · 검색에 넣지 않는다).
// context_version은 DB 트리거가 올린다 (20261104000000_context_layer 8장). 묶음은 만들 때의 version을 적고, 지금 값이 더 크면 stale 후보다(6.3).

export type ContextMemberRef = { kind: "action"; actionId: string } | { kind: "source"; sourceId: string } | { kind: "person"; personId: string };

/** 멤버를 context_members 열로 (종류마다 열 하나) */
export function memberColumns(member: ContextMemberRef) {
  return {
    member_kind: member.kind,
    action_id: member.kind === "action" ? member.actionId : null,
    source_id: member.kind === "source" ? member.sourceId : null,
    person_id: member.kind === "person" ? member.personId : null,
  };
}

/** 같은 범위에 같은 멤버는 한 번 (unique). upsert의 충돌 열 */
export function memberConflictColumns(member: ContextMemberRef): "context_id,action_id" | "context_id,source_id" | "context_id,person_id" {
  return member.kind === "action" ? "context_id,action_id" : member.kind === "source" ? "context_id,source_id" : "context_id,person_id";
}

/** 묶음을 만든 뒤 범위가 바뀌었나 (6.3 stale 판정의 첫 조건. 무엇이 바뀌었는지 · 전달할지는 코디네이터 C2가 정한다) */
export function bundleIsStale(bundleContextVersion: number | null, currentContextVersion: number | null): boolean {
  return bundleContextVersion !== null && currentContextVersion !== null && bundleContextVersion < currentContextVersion;
}
