import type { PGlite } from "@electric-sql/pglite";
import { afterEach } from "vitest";

import { openPglite } from "./pglite-template";

// 시험마다 새 DB를 만드는 팩토리(업그레이드 · 되돌리기 회귀)용. 만든 인스턴스를 기억해 두었다가 시험이 끝날 때마다 닫는다.
// 왜: 닫지 않으면 PGlite 인스턴스(WASM 힙 약 0.5–0.9GB)가 프로세스가 끝날 때까지 쌓인다 — review-summary는 한 파일에 일곱 개, 약 3.5GB.
// 메모리가 이미 포화인 개발 머신에서 그 증가가 압축기 과부하와 전체 정지로 이어지는 것을 측정했다 (handoffs 노트 "시간 초과의 원인 분석").
// 호출한 파일의 모든 시험에 afterEach가 걸린다. 닫을 때의 오류는 무시한다(이미 닫힌 인스턴스 등).
//
// 늦은 생성: 시간 초과로 끝난 시험의 본문은 취소되지 않고 계속 돈다(Vitest의 withTimeout은 원래 promise를 취소하지 않고, 실패를 잡은 뒤 afterEach를 부른다).
// 그 본문이 afterEach 이후에 PGlite 생성을 끝내면, "세대"가 달라진 것을 보고 그 인스턴스를 바로 닫고 오류를 던진다 (끝난 시험의 본문만 실패하고, 다음 시험의 인스턴스는 건드리지 않는다).
// 세대는 afterEach마다 하나 오르며, 인스턴스는 **생성을 시작할 때** 잡은 세대로 판정한다(생성이 끝난 뒤 전역을 읽지 않는다).
export function freshPgliteForEachTest(scripts: string[] = [], opener: (scripts: string[]) => Promise<PGlite> = openPglite): () => Promise<PGlite> {
  const open = new Set<PGlite>();
  let generation = 0;
  afterEach(async () => {
    generation++;
    const mine = [...open];
    open.clear();
    for (const db of mine) await db.close().catch(() => undefined);
  });
  return async () => {
    const started = generation;
    const db = await opener(scripts);
    if (started !== generation) {
      await db.close().catch(() => undefined);
      throw new Error("PGlite가 시험이 끝난 뒤에 만들어져 닫았다 (늦은 생성)");
    }
    open.add(db);
    return db;
  };
}
