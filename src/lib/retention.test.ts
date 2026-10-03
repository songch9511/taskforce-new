import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { EXECUTION_TEXT_RETENTION_DAYS, RAW_TEXT_RETENTION_DAYS, retentionCutoff, SLACK_DISCONNECTED_QUOTE } from "./retention";

describe("retentionCutoff", () => {
  it("원문은 90일 보관한다", () => {
    expect(RAW_TEXT_RETENTION_DAYS).toBe(90);
    expect(retentionCutoff(new Date("2026-12-26T00:00:00Z"))).toEqual(new Date("2026-09-27T00:00:00Z"));
  });

  it("실행의 글(요청 · 지시 · 받는 사람 후보 · 되묻는 질문)은 run이 끝난 뒤 90일 보관한다 (처리방침 D9a-1 초안 5장의 90일, 끝난 시각 기준)", () => {
    expect(EXECUTION_TEXT_RETENTION_DAYS).toBe(90);
  });
});

describe("SLACK_DISCONNECTED_QUOTE", () => {
  // 같은 자리 표시 글자가 SQL(purge_slack_sources가 인용을 바꿈)과 Swift(RemovedQuote가 앱 문구로 보임)에도 있다.
  // 하나만 바꾸면 넘기기 · 물어보기 · 매칭이 자리 표시를 인용으로 쓰고, 앱은 지운 인용을 그대로 보인다.
  it("SQL(purge_slack_sources의 가장 최근 정의) · Swift와 같은 글자다", () => {
    const root = path.resolve(import.meta.dirname, "../..");
    const dir = path.join(root, "supabase/migrations");
    const definitions = readdirSync(dir)
      .filter((file) => file.endsWith(".sql"))
      .sort()
      .map((file) => readFileSync(path.join(dir, file), "utf8"))
      .filter((sql) => /function\s+public\.purge_slack_sources\s*\(/i.test(sql));
    expect(definitions.at(-1)).toContain(`set quote = '${SLACK_DISCONNECTED_QUOTE}'`);

    const swift = readFileSync(path.join(root, "apple/Packages/TaskforceKit/Sources/TaskforceKit/EvidenceDigest.swift"), "utf8");
    expect(swift).toContain(`slackDisconnected = "${SLACK_DISCONNECTED_QUOTE}"`);
  });
});
