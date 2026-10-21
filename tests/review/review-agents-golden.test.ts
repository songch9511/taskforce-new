import { readFileSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, afterEach, beforeEach, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { loadReturnSummary } from "@/lib/review/return-summary";
import { loadReview } from "@/lib/review/review";

import { adminOf, createCoordinatorDb } from "../coordinator/support";
import { GOLDEN_HORIZON, GOLDEN_NOW, GOLDEN_USER, markGoldenCleared, seedGoldenWorld } from "./review-agents-golden.fixture";

// OA D4b-s P3: gate가 꺼져 있으면 Review · 복귀 요약의 **전체 응답 JSON**이 D4b-s 이전(base 97a43e1) 코드가 낸 것과 글자 단위로 같다.
// 기준은 `review-agents-golden.json`: base 코드로 같은 fixture(`review-agents-golden.fixture.ts`)를 돌려 기록했다 (complete · sources · changes · cursor · init_token 포함).
// 기록 방법: base 97a43e1을 `git archive`로 풀어 fixture + 임시 기록 시험(loadReview · loadReturnSummary를 같은 인자로 부르고 결과를 JSON.stringify(…, null, 2)로 씀)을 돌렸다. 세 번 기록해 같은 바이트임을 확인했다.
// fixture에는 에이전트 입력(질문 · 결과 준비 · 경로 충돌)이 같은 사용자에게 들어 있다 — 닫힌 gate가 그것을 읽으면 응답이 달라져 이 시험이 깨진다.
// 기준 JSON을 다시 기록해야 하는 때: C3 응답 모양이나 fixture가 바뀐 마이그레이션이 base에 들어왔을 때뿐이다. D4b-s 코드를 맞추려고 고치지 않는다.

const golden = JSON.parse(readFileSync(path.join(__dirname, "review-agents-golden.json"), "utf8")) as { recorded: string; review: unknown; returnSummary: unknown; returnSummaryCleared: unknown };
const bytes = (value: unknown) => JSON.stringify(value);

let db: PGlite;
let admin: SupabaseClient;

beforeAll(async () => {
  db = await createCoordinatorDb();
  await seedGoldenWorld(db);
  admin = adminOf(db);
}, 120_000);
afterAll(() => db.close());
afterEach(() => vi.unstubAllEnvs());

const review = (client: SupabaseClient, agentAdapters?: readonly string[]) =>
  loadReview(client, GOLDEN_USER, GOLDEN_NOW, { coordinatorEnabled: false, timeZone: async () => "Asia/Seoul", agentAdapters });
const summary = (client: SupabaseClient, agentAdapters?: readonly string[]) => loadReturnSummary(client, GOLDEN_USER, GOLDEN_NOW, { horizon: GOLDEN_HORIZON, agentAdapters });
const spy = (client: SupabaseClient) => {
  const calls: string[] = [];
  return { calls, client: { ...client, rpc: (name: string, args: unknown) => (calls.push(name), (client.rpc as (n: string, a: unknown) => unknown)(name, args)) } as unknown as SupabaseClient };
};

describe("기준 JSON (base 97a43e1)", () => {
  it("fixture가 일을 한다: C3 결정 · 변화(action_event · run · message) · 커서 · 기준점 토큰이 모두 기준 JSON에 있다 (빈 비교가 아니다)", () => {
    const text = JSON.stringify(golden);
    expect(text).toContain('"kind":"confirm"');
    expect(text).toContain('"kind":"run_input"');
    for (const needle of ['"source":"action_event"', '"source":"run"', '"source":"message"', '"init_token":"i1.', '"cursor":"c3.', '"baseline":"cleared"', '"baseline":"never_cleared"']) expect(text, needle).toContain(needle);
    expect(text).not.toMatch(/agent_|result_ready|path_conflict/);
  });
});

describe("U6 gate 꺼짐 = 전체 JSON 바이트 동일", () => {
  it("Review: 켜진 adapter가 없다고 주입하면(빈 배열) 전체 응답이 기준과 글자 단위로 같고 review_agent_inputs를 부르지 않는다", async () => {
    const t = spy(admin);
    expect(bytes(await review(t.client, []))).toBe(bytes(golden.review));
    expect(t.calls).not.toContain("review_agent_inputs");
  });

  it("Review: 환경 기본값(플래그 모두 꺼짐)도 같다", async () => {
    const t = spy(admin);
    expect(bytes(await review(t.client))).toBe(bytes(golden.review));
    expect(t.calls).not.toContain("review_agent_inputs");
  });

  it("대화 v2만 켜고 adapter 플래그가 없어도(켜진 adapter 없음) Review · 복귀 요약이 같다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const t = spy(admin);
    expect(bytes(await review(t.client))).toBe(bytes(golden.review));
    expect(bytes(await summary(t.client))).toBe(bytes(golden.returnSummary));
    expect(t.calls).not.toContain("review_agent_inputs");
  });

  it("복귀 요약 (읽음 기준 없음): 빈 배열 · 환경 기본값 모두 전체 응답(complete · sources · changes · cursor · init_token)이 기준과 글자 단위로 같다", async () => {
    const t = spy(admin);
    expect(bytes(await summary(t.client, []))).toBe(bytes(golden.returnSummary));
    expect(bytes(await summary(t.client))).toBe(bytes(golden.returnSummary));
    expect(t.calls).not.toContain("review_agent_inputs");
  });

  it("복귀 요약 (Clear한 적 있음): run · 메시지 변화 · since · 커서까지 전체 응답이 기준과 글자 단위로 같다. gate를 열면 달라진다 (닫힘이 우연히 같은 게 아니다)", async () => {
    await markGoldenCleared(db);
    const t = spy(admin);
    expect(bytes(await summary(t.client, []))).toBe(bytes(golden.returnSummaryCleared));
    expect(bytes(await summary(t.client))).toBe(bytes(golden.returnSummaryCleared));
    expect(t.calls).not.toContain("review_agent_inputs");
    const open = await summary(admin, ["agent:codex"]);
    expect(bytes(open)).not.toBe(bytes(golden.returnSummaryCleared));
    expect(open.items.flatMap((item) => item.decisions.map((d) => d.kind)).sort()).toEqual(["agent_question", "confirm", "path_conflict", "result_ready", "run_input"]);
  });

  it("gate를 열면 Review 응답이 달라진다: 에이전트 결정 셋이 더해지고 C3 종류의 묶음은 기준과 같다", async () => {
    const open = await review(admin, ["agent:codex"]);
    expect(bytes(open)).not.toBe(bytes(golden.review));
    expect((open.decisions ?? []).map((g) => g.kind).sort()).toEqual(["agent_question", "confirm", "path_conflict", "result_ready", "run_input"]);
    const c3 = (open.decisions ?? []).filter((g) => g.kind === "confirm" || g.kind === "run_input");
    expect(bytes(c3)).toBe(bytes((golden.review as { decisions: unknown[] }).decisions));
  });
});

beforeEach(() => { vi.stubEnv("AGENT_BETA_USER_IDS", GOLDEN_USER); vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true"); });
