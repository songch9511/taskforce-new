import { randomUUID } from "node:crypto";

import { projectAction } from "@/lib/actions/project";
import { actionRowValues, storedReasons } from "@/lib/actions/rows";
import type { Claim } from "@/lib/pipeline/resolve";

// 실행 receipt → Claim/Evidence (docs/EXECUTION.md 9장, CLAUDE.md 원칙 2 · 5, A38 · A55 · A57).
// 끝낸 초안 단계 하나 = receipt 원문(kind execution) 하나 + Claim(origin execution, field artifact, 값 = 산출물 id) + 근거(executed)
// + 이벤트(artifact_created, actor agent). 쓰기는 DB 함수 write_execution_receipt가 write_action과 한 트랜잭션에서 한다.
// receipt는 Action을 바꾸지 않는다: 초안은 완료가 아니고(A38), 사용자가 끝낸 할 일도 그대로다(A57). DB 함수가 잠근 Action 행의 값을
// 그대로 다시 쓰고, 그 전에 여기서 Claim을 더해 진실 판정 순수 함수(projectAction)로 다시 계산해도 같은지 확인한다(원칙 5).
// 실행 결과는 사용자 Claim이 아니다(A55).
// receipt 글은 산출물 제목만 담는다(본문 · 원문 · 요청은 담지 않는다). 로그에는 단계 id와 오류 이름만 남긴다.

/** receipt를 붙일 끝낸(called) 초안 단계: 단계 · run의 Action · 산출물 (DB에서 읽은 값) */
export type ReceiptTarget = {
  stepId: string;
  runId: string;
  userId: string;
  actionId: string;
  artifact: { id: string; title: string; createdAt: Date };
};

/** receipt를 붙일 Action의 지금 상태 (actions 행 · Claim) */
export type ReceiptAction = { version: number; title: string; confirmReasons: string[]; claims: Claim[] };

/** write_execution_receipt의 p_receipt. 사용자 · Action · 종류 · 시각 · Claim 필드와 값 · 근거 · 이벤트는 DB 함수가 정한다 */
export type DraftReceipt = {
  source: { title: string | null; raw_text: string; external_url: string };
  claim: { id: string; quote: string; speaker_role: Claim["speakerRole"]; certainty: Claim["certainty"]; directness: Claim["directness"]; audience: Claim["audience"] };
};

/** written: 붙였다 · exists: 이미 붙어 있다 · conflict: Action 버전이 어긋나 아무것도 쓰지 않았다 */
export type ReceiptWriteResult = "written" | "exists" | "conflict";

/** receipt 쓰기가 쓰는 DB 연산. 운영은 receipt-store.ts(supabase · service role), 테스트는 같은 SQL을 PGlite에서 부른다 */
export interface ReceiptStore {
  /** 끝낸 초안 단계와 그 산출물 · run의 Action. 아니면(없음 · 초안이 아님 · 끝내지 않음 · 산출물 없음) null */
  receiptTarget(stepId: string): Promise<ReceiptTarget | null>;
  loadAction(userId: string, actionId: string): Promise<ReceiptAction | null>;
  /** DB 함수 write_execution_receipt (Action 값은 DB 함수가 잠근 행 그대로 쓴다) */
  writeReceipt(stepId: string, expectedVersion: number, receipt: DraftReceipt): Promise<ReceiptWriteResult>;
  /** receipt가 아직 없는 끝낸 초안 단계 (DB 함수 missing_execution_receipts, 하루 안) */
  missingReceipts(limit: number): Promise<string[]>;
}

export class ReceiptWriteError extends Error {
  constructor(readonly code: "not_found" | "conflict" | "changes_action") {
    super(`receipt를 쓰지 못함 (${code})`);
    this.name = "ReceiptWriteError";
  }
}

/** receipt 원문의 제목 · 글에 넣는 산출물 제목 길이 상한 (원문 제목 상한 200과 같다) */
const TITLE_CHARS = 200;
/** receipt 글의 앞머리. 인용(Claim · 근거)은 이 글 전체다 */
export const DRAFT_RECEIPT_PREFIX = "초안 저장";

/** 산출물 딥링크 (앱 URL scheme `taskforce://`). 외부 주소가 아니라 앱 안의 산출물을 가리킨다 */
export const artifactLink = (artifactId: string) => `taskforce://artifacts/${artifactId}`;

/** 모델이 만든 제목을 한 줄로: 줄바꿈 · 연속 공백을 하나로, 앞뒤 공백 제거, 길면 자른다(글자 단위: 이모지를 반으로 자르지 않는다). 비면 null */
export function receiptTitle(title: string): string | null {
  const line = title.replace(/\s+/g, " ").trim();
  if (!line) return null;
  const chars = Array.from(line);
  return chars.length > TITLE_CHARS ? `${chars.slice(0, TITLE_CHARS - 1).join("")}…` : line;
}

/** receipt 원문과 그 Claim (판정에 넣을 값). 인용 = receipt 글 한 줄 */
export function buildDraftReceipt(target: ReceiptTarget, claimId: string): { receipt: DraftReceipt; claim: Claim } {
  const title = receiptTitle(target.artifact.title);
  const line = title ? `${DRAFT_RECEIPT_PREFIX}: ${title}` : DRAFT_RECEIPT_PREFIX;
  // 실행기가 사용자 대신 만든 사용자의 초안이다: 화자는 나, 확정 · 직접, 아직 상대에게 보내지 않았으므로 private.
  // 판정은 artifact 필드를 계산하지 않으므로 이 속성은 값에 영향이 없다(기록용)
  const attributes = { speakerRole: "me", certainty: "firm", directness: "first_hand", audience: "private" } as const;
  return {
    receipt: {
      source: { title, raw_text: line, external_url: artifactLink(target.artifact.id) },
      claim: {
        id: claimId,
        quote: line,
        speaker_role: attributes.speakerRole,
        certainty: attributes.certainty,
        directness: attributes.directness,
        audience: attributes.audience,
      },
    },
    claim: {
      id: claimId,
      field: "artifact",
      value: target.artifact.id,
      occurredAt: target.artifact.createdAt,
      ...attributes,
      // DB에는 채널 없이(null) 들어가고, 다시 읽으면 claimFromRow가 note로 읽는다
      channel: "note",
      origin: "execution",
      state: "active",
    },
  };
}

/**
 * receipt Claim을 더해 다시 판정해도(원칙 5) Action 행 값이 붙이기 전 판정과 같은지 확인한다. artifact Claim은 필드를 바꾸지 않으므로 같아야 하고,
 * 다르면 쓰지 않는다(changes_action): 초안이 Action을 바꾸는 일은 없다(A38 · A57). DB 함수는 잠근 행 값을 그대로 쓴다.
 */
export function assertReceiptKeepsAction(action: ReceiptAction, claim: Claim): void {
  const reasons = storedReasons(action.confirmReasons);
  const before = actionRowValues(projectAction(action.title, action.claims, reasons));
  const after = actionRowValues(projectAction(action.title, [...action.claims, claim], reasons));
  if (JSON.stringify(before) !== JSON.stringify(after)) throw new ReceiptWriteError("changes_action");
}

/** 버전이 어긋나면 다시 읽고 다시 계산하는 횟수 (lib/actions/db-store.ts retryOnConflict와 같다) */
const WRITE_TRIES = 3;

/**
 * 끝낸 초안 단계의 receipt를 Action에 붙인다. 실행기가 complete_internal_step이 true를 돌려준 초안 단계마다 부른다.
 * 다시 불러도 같다(이미 붙었으면 exists). 단계가 끝낸 초안 단계가 아니거나 산출물 · Action이 없으면 ReceiptWriteError("not_found").
 */
export async function writeDraftReceipt(store: ReceiptStore, stepId: string, newId: () => string = randomUUID): Promise<"written" | "exists"> {
  const target = await store.receiptTarget(stepId);
  if (!target) throw new ReceiptWriteError("not_found");
  const { receipt, claim } = buildDraftReceipt(target, newId());
  for (let i = 0; i < WRITE_TRIES; i++) {
    const action = await store.loadAction(target.userId, target.actionId);
    if (!action) throw new ReceiptWriteError("not_found");
    assertReceiptKeepsAction(action, claim);
    const result = await store.writeReceipt(stepId, action.version, receipt);
    if (result !== "conflict") return result;
  }
  throw new ReceiptWriteError("conflict");
}

/**
 * sweep의 보조 안전망: receipt가 없는 끝낸 초안 단계(하루 안)마다 receipt를 붙인다. 하나가 실패해도 다음 단계를 한다.
 * 실패는 단계 id와 오류 이름 · 코드만 로그에 남긴다.
 */
export async function writeMissingReceipts(store: ReceiptStore, limit = 20): Promise<{ written: number; failed: number }> {
  let written = 0;
  let failed = 0;
  for (const stepId of await store.missingReceipts(limit)) {
    try {
      if ((await writeDraftReceipt(store, stepId)) === "written") written++;
    } catch (error) {
      failed++;
      const reason = error instanceof ReceiptWriteError ? error.code : error instanceof Error ? error.name : "unknown";
      // DB 오류면 SQLSTATE도 남긴다 (사용자 글이 없는 코드)
      const code = error instanceof ReceiptWriteError ? undefined : (error as { code?: unknown } | null)?.code;
      console.error(JSON.stringify({ event: "execution_receipt_failed", step: stepId, reason, ...(typeof code === "string" ? { code } : {}) }));
    }
  }
  return { written, failed };
}
