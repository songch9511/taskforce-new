import type { MemoryEditRequest, MemoryItem } from "@/lib/api/contract";

// 기억 확인 · 정정 · 잊기 · 범위 옮기기 (B3)의 순수 규칙. DB 쓰기는 memory-writes.ts(remember_memory_item · forget_memory_item · move_memory_item).
// 판정은 이 모듈과 DB 함수에 있다. 모델도 앱의 표시도 확인을 대신하지 못한다: 확인은 사용자가 보낸 요청(version 포함)뿐이다.
//
// 정책 보류 (docs/context-layer.md 8장, 활성화하지 않음):
//   (a) Slack 원문에서 온 후보(inferred)의 확인 — 모델이 Slack 글에서 만든 문장이 D3(Slack 연결을 끊으면 지움)를 벗어나 explicit으로 남는다. 확인 불가(unavailable).
//       같은 이유로 Slack에서 온 observed · inferred 항목을 글자만 그대로 두고 "정정"하는 것도 확인의 우회라 막는다. 새 글을 쓰는 Edit와 Forget은 허용.
//   (b) observed · inferred의 범위 변경 — 거절 (move_memory_item이 explicit만 옮긴다).
//   (c) 글이 지워진(source_purged) 항목의 확인 — 확인할 글이 없어 불가. Edit(사용자가 새 글을 씀) · Forget은 허용.
//   (d) 접근을 잃은(access_lost_at, 문서 단위) 원문에서 온 후보의 확인 — 접근 상실 원문은 새 검색 · 묶음에서 빠지는데 확인된 explicit은 묶음에 들어가므로(B1 보존) 승격을 막는다.
//       (a)와 같은 방식으로 글자 그대로의 Edit 우회도 막는다. 새 글 Edit · Forget은 허용. 원래 explicit 사용자 기억과 사용자가 새로 쓴 정정은 바꾸지 않는다(B1 보존 규칙).
//       복원(access_lost null) 뒤에는 다시 확인할 수 있다. 제품 결정 전까지의 보수안이다.

/** 기억 쓰기 한 번의 결과. not_found는 없거나 남의 항목(존재를 드러내지 않는다), conflict는 version 충돌 · 이미 정정 · 잊음, unavailable은 정책 거절 */
export type MemoryWriteOutcome =
  | { status: "ok"; item: MemoryItem }
  | { status: "not_found" }
  | { status: "conflict" }
  | { status: "unavailable" }
  | { status: "invalid" };

/** 같은 글인가 (NFKC · 소문자 · 공백 하나로 접어 견준다). 대소문자 · 공백만 바꾼 "정정"은 새 글이 아니다 */
export function sameStatement(a: string, b: string): boolean {
  const fold = (text: string) => text.normalize("NFKC").toLowerCase().replace(/\s+/gu, " ").trim();
  return fold(a) === fold(b);
}

/** 이 요청이 본 상태가 낡았는가: 이미 정정 · 잊은 항목이거나 version이 다르다 (이 셋은 한 방향으로만 바뀐다) */
export function isStale(row: Pick<MemoryItem, "superseded_at" | "revoked_at" | "version">, expectedVersion: number): boolean {
  return row.superseded_at !== null || row.revoked_at !== null || row.version !== expectedVersion;
}

export type ConfirmPlan = { ok: true } | { ok: false; reason: "conflict" | "unavailable" };

/**
 * 추정(inferred) 후보의 확인. 새 explicit 행이 후보를 정정한다(같은 범위 · kind · subject, 글 · 값 · 출처를 그대로).
 * sourceRestricted: 출처 원문이 승격을 막는 상태다 — Slack에서 왔거나(연결이 Slack · Slack 끊기로 지운 원문 · 링크가 Slack, (a)) 접근을 잃었거나((d)),
 * 출처 상태를 알 수 없다 (memory-writes.ts restrictedSource)
 */
export function planConfirm(row: MemoryItem, expectedVersion: number, sourceRestricted: boolean): ConfirmPlan {
  if (isStale(row, expectedVersion)) return { ok: false, reason: "conflict" };
  // 추정만 확인한다. 글이 지워진(source_purged) 항목은 observed라 여기서도 걸린다
  if (row.origin !== "inferred" || row.source_purged) return { ok: false, reason: "unavailable" };
  if (sourceRestricted) return { ok: false, reason: "unavailable" };
  return { ok: true };
}

/** 새 explicit 행에 쓸 값 (remember_memory_item의 새 행). 범위 · kind · subject는 DB가 옛 행에서 물려받는다 */
export type EditWrite = { statement: string; value: Record<string, unknown>; valid_from: string | null; valid_until: string | null };

export type EditPlan = { ok: true; write: EditWrite } | { ok: false; reason: "conflict" | "unavailable" | "invalid" };

/**
 * 정정(Edit). 요청에 없는 값(value · valid_from · valid_until)은 옛 행의 것을 그대로 쓴다. 비우기: value는 {}(null은 계약상 400), valid_from · valid_until은 null.
 * 출처(source_ref)는 잇지 않는다: 새 글은 사용자가 쓴 것이고 옛 행이 이력으로 출처를 남긴다.
 * 출처가 막힌 상태(Slack · 접근 상실)인 observed · inferred 항목은 옛 행의 값도 잇지 않고(그 출처 글에서 읽은 구조화 값이다) 글이 달라야 한다(확인의 우회 막기).
 */
export function planEdit(row: MemoryItem, request: MemoryEditRequest, sourceRestricted: boolean): EditPlan {
  if (isStale(row, request.expected_version)) return { ok: false, reason: "conflict" };
  const guarded = sourceRestricted && row.origin !== "explicit";
  if (guarded && sameStatement(row.statement, request.statement)) return { ok: false, reason: "unavailable" };
  const inherit = !guarded;
  const write: EditWrite = {
    statement: request.statement,
    value: request.value ?? (inherit ? row.value : {}),
    valid_from: request.valid_from !== undefined ? request.valid_from : inherit ? row.valid_from : null,
    valid_until: request.valid_until !== undefined ? request.valid_until : inherit ? row.valid_until : null,
  };
  if (write.valid_from && write.valid_until && Date.parse(write.valid_from) > Date.parse(write.valid_until)) return { ok: false, reason: "invalid" };
  return { ok: true, write };
}
