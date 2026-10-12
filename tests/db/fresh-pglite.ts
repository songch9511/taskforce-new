import type { PGlite } from "@electric-sql/pglite";
import { afterEach } from "vitest";

import { openPglite } from "./pglite-template";

// 시험마다 새 DB를 만드는 팩토리(업그레이드 · 되돌리기 회귀)용. 만든 인스턴스를 기억해 두었다가 시험이 끝날 때마다 닫는다.
// 왜: 닫지 않으면 PGlite 인스턴스(WASM 힙 약 0.5–0.9GB)가 프로세스가 끝날 때까지 쌓인다 — review-summary는 한 파일에 일곱 개, 약 3.5GB.
// 메모리가 이미 포화인 개발 머신에서 그 증가가 압축기 과부하와 전체 정지로 이어지는 것을 측정했다 (handoffs 노트 "시간 초과의 원인 분석").
// 호출한 파일의 모든 시험에 afterEach가 걸린다. 닫을 때의 오류는 무시한다(이미 닫힌 인스턴스 등).
export function freshPgliteForEachTest(scripts: string[] = []): () => Promise<PGlite> {
  const open: PGlite[] = [];
  afterEach(async () => {
    for (const db of open.splice(0)) await db.close().catch(() => undefined);
  });
  return async () => {
    const db = await openPglite(scripts);
    open.push(db);
    return db;
  };
}
