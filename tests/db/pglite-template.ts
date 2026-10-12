import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";

import { PGlite } from "@electric-sql/pglite";
import { vector } from "@electric-sql/pglite-pgvector";

// PGlite 시험 DB를 매번 처음부터(initdb + 마이그레이션 수십 개) 띄우지 않는다.
//
// 왜 (측정, 기본 시험 제한 5초): PGlite를 처음부터 새로 띄우면 이벤트 루프를 막는 동기 WASM 작업(initdb)이 돌고, 프로세스 CPU를 한 번에 약 3초(여러 스레드 합,
// 프로세스의 첫 부팅) 또는 약 1.2초(그 뒤 부팅) 쓴다 — WASM 모듈 컴파일(17ms)이나 fsBundle 읽기가 아니라 initdb가 대부분이다. 마이그레이션 49개를 적용하는 데 약 0.5–1초가 더 든다.
// 업그레이드 시험처럼 시험마다 새 DB를 만드는 시험은 시험 한 건이 CPU 약 1.5–3.5초를 쓰므로, 프로세스가 CPU를 1코어 정도만 받아도 5초에 닿는다(여러 PGlite 프로세스가 CPU를 다투면 더 쉽게).
// 템플릿(initdb가 끝난 클러스터, 또는 마이그레이션까지 적용된 클러스터)을 한 번 만들어 dumpDataDir → loadDataDir로 복제하면 initdb(와 마이그레이션 적용)가 사라진다:
// 같은 시나리오를 같은 순간에 번갈아 돌린 측정에서 시험 한 건의 시간 · CPU가 약 50% 줄었다.
//
// 규칙:
//  - 시험 코드 · 단언 · 마이그레이션 SQL은 그대로다. 복제한 DB는 처음부터 만든 DB와 같은 상태여야 한다 (tests/db/pglite-template.test.ts가 객체 지문을 견준다).
//  - 캐시 키 = PGlite 버전 + 스크립트 내용. 마이그레이션이 바뀌면 새 템플릿이다. 캐시는 node_modules/.cache 아래의 파일이고(git 무시), 원자적 rename으로 쓴다.
//  - 캐시를 못 쓰거나 TASKFORCE_PGLITE_TEMPLATE=0이면 예전처럼 처음부터 만든다 (시험이 환경에 막히지 않는다).

const CACHE_DIR = path.resolve(__dirname, "../../node_modules/.cache/taskforce-pglite-template");
export const PGLITE_TEMPLATE_CACHE_DIR = CACHE_DIR;
const PGLITE_VERSION = (JSON.parse(readFileSync(path.resolve(__dirname, "../../node_modules/@electric-sql/pglite/package.json"), "utf8")) as { version: string }).version;

export const templatesEnabled = () => process.env.TASKFORCE_PGLITE_TEMPLATE !== "0";

// PGlite 기본 shared_buffers는 128MB라 인스턴스마다 RSS가 약 120MB 더 상주한다(측정: 템플릿 복제 부팅 605–620MB → shared_buffers=16MB 489–490MB, 약 20% 감소).
// 시험 DB에는 16MB로 충분하다. 테스트 인프라 설정이며 의미는 같다: shared_buffers는 캐시 크기일 뿐 쿼리 결과를 바꾸지 않고, 계획 비용 모델은 effective_cache_size를 쓴다.
// TASKFORCE_PGLITE_SHARED_BUFFERS=default면 PGlite 기본값(128MB)으로 돌린다 (전후 비교 · 되돌리기용), 다른 값은 그대로 shared_buffers에 쓴다.
export const PGLITE_SHARED_BUFFERS = process.env.TASKFORCE_PGLITE_SHARED_BUFFERS || "16MB";
const confOptions = (): { postgresqlconf?: string[] } => (PGLITE_SHARED_BUFFERS === "default" ? {} : { postgresqlconf: [`shared_buffers=${PGLITE_SHARED_BUFFERS}`] });

const key = (kind: string, scripts: string[]) => createHash("sha256").update(PGLITE_VERSION).update("\0").update(PGLITE_SHARED_BUFFERS).update("\0").update(kind).update("\0").update(scripts.join("\0\0")).digest("hex").slice(0, 24);

function readCache(file: string): Buffer | null {
  try {
    return readFileSync(file);
  } catch {
    return null;
  }
}

function writeCache(file: string, bytes: Uint8Array) {
  try {
    mkdirSync(CACHE_DIR, { recursive: true });
    const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
    writeFileSync(tmp, bytes);
    renameSync(tmp, file); // 같은 파일 시스템 안의 rename은 원자적이다: 읽는 쪽은 완성된 파일만 본다
  } catch {
    // 캐시를 못 쓰면 이 프로세스 안에서만 쓴다
  }
}

const memo = new Map<string, Promise<Blob>>();

/** 스크립트를 순서대로 적용한 클러스터의 템플릿 (캐시 → 없으면 만들어 캐시). 스크립트가 없으면 initdb만 된 빈 클러스터 */
export function clusterTemplate(scripts: string[]): Promise<Blob> {
  const k = key(scripts.length === 0 ? "bare" : "migrated", scripts);
  let promise = memo.get(k);
  if (!promise) {
    promise = (async () => {
      const file = path.join(CACHE_DIR, `${k}.tar`);
      const cached = readCache(file);
      if (cached) return new Blob([new Uint8Array(cached)]);
      const db = new PGlite({ extensions: { vector }, ...confOptions() });
      for (const sql of scripts) await db.exec(sql);
      const tarball = await db.dumpDataDir("none");
      await db.close();
      writeCache(file, new Uint8Array(await tarball.arrayBuffer()));
      return tarball;
    })();
    memo.set(k, promise);
    promise.catch(() => memo.delete(k));
  }
  return promise;
}

/** 새 PGlite. 템플릿이 있으면 그 클러스터를 복제한다 (initdb를 건너뛴다). 템플릿을 못 쓰면 처음부터 만든다 */
export async function openPglite(scripts: string[] = []): Promise<PGlite> {
  if (templatesEnabled()) {
    try {
      const db = new PGlite({ extensions: { vector }, ...confOptions(), loadDataDir: await clusterTemplate(scripts) });
      await db.waitReady;
      return db;
    } catch {
      // 템플릿을 못 읽으면 아래의 예전 방식으로
    }
  }
  const db = new PGlite({ extensions: { vector }, ...confOptions() });
  for (const sql of scripts) await db.exec(sql);
  return db;
}
