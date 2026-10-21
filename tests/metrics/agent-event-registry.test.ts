import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { AGENT_EVENTS, BILLING_EVENTS, PRE_OA_TYPES, agentUsage } from "@/lib/metrics/agents";

// OA I-oa 7.4: 이벤트 발생 지점을 정적으로 대조한다. 최신 CHECK ↔ 등록부(src/lib/metrics/agents.ts) ↔ 원천 함수(최신 정의) ↔ 시험 파일.
// 다음 WP가 metric_events type을 더하면(블록 v4) R1이 실패해 등록부 · 카드를 고치게 한다.

const ROOT = path.resolve(import.meta.dirname, "../..");
const MIGRATIONS = path.join(ROOT, "supabase/migrations");
const migrations = new Map(
  readdirSync(MIGRATIONS)
    .filter((name) => name.endsWith(".sql"))
    .sort()
    .map((name) => [name, readFileSync(path.join(MIGRATIONS, name), "utf8")] as const),
);

/** SQL 주석(한 줄 `--` · 블록)을 지운다: 주석 속 제약 이름 언급이 "그 제약을 만진 파일"로 읽히지 않게 */
const stripSqlComments = (sql: string) => sql.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/--[^\n]*/g, " ");

/**
 * 파일 이름 순으로 **가장 나중에 metric_events_type_check를 만지는 파일**의 마지막 `CONSTRAINT … CHECK (type IN ('…', …))` type 목록.
 * 대소문자 · 공백 · 줄바꿈 · 따옴표 붙은 이름을 허용한다. 그 파일이 제약을 만지는데 이 모양으로 해석하지 못하면 이전 목록으로 돌아가지 않고 던진다.
 */
function parseLatestTypeCheck(files: ReadonlyMap<string, string>): string[] {
  const names = [...files.keys()].sort();
  for (let i = names.length - 1; i >= 0; i--) {
    const text = stripSqlComments(files.get(names[i])!);
    if (!/metric_events_type_check/i.test(text)) continue;
    const definitions = [...text.matchAll(/constraint\s+"?metric_events_type_check"?\s+check\s*\(\s*type\s+in\s*\(([^)]*)\)\s*\)/gi)];
    const list = definitions.at(-1)?.[1];
    // 목록은 따옴표 글자 상수와 쉼표뿐이어야 한다 (함수 · 서브쿼리 · = any(array[…])는 해석하지 못한 것으로 본다)
    if (list === undefined || !/^\s*'[^']*'(?:\s*,\s*'[^']*')*\s*$/.test(list)) {
      throw new Error(`${names[i]}: metric_events_type_check를 바꾸는데 CHECK (type IN ('…', …)) 모양으로 해석할 수 없다 — 이 시험의 해석기를 고쳐라`);
    }
    return [...list.matchAll(/'([^']*)'/g)].map((m) => m[1]);
  }
  throw new Error("metric_events_type_check를 찾지 못했다");
}

const latestTypeCheck = () => parseLatestTypeCheck(migrations);

/** `create [or replace] function public.<name>(`의 마지막 정의(파일 이름 순)의 본문 ($$ … $$) */
function latestFunctionBody(name: string): { file: string; body: string } | null {
  const pattern = new RegExp(`create\\s+(?:or\\s+replace\\s+)?function\\s+public\\.${name}\\s*\\(`, "gi");
  let latest: { file: string; text: string; start: number } | null = null;
  for (const [file, text] of migrations) {
    for (const match of text.matchAll(pattern)) latest = { file, text, start: match.index };
  }
  if (!latest) return null;
  const rest = latest.text.slice(latest.start);
  const open = /\$(\w*)\$/.exec(rest);
  if (!open) return null;
  const from = open.index + open[0].length;
  const to = rest.indexOf(open[0], from);
  return { file: latest.file, body: rest.slice(from, to) };
}

function walk(dir: string, accept: (file: string) => boolean, skip: (dir: string) => boolean = () => false): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = path.join(dir, entry);
    const stat = statSync(full);
    if (stat.isDirectory()) {
      if (entry === "node_modules" || entry === ".build" || entry === ".git" || skip(full)) continue;
      out.push(...walk(full, accept, skip));
    } else if (accept(full)) out.push(full);
  }
  return out;
}

const quoted = (type: string) => new RegExp(`["'\`]${type}["'\`]`);

describe("R1 가드 자체: 최신 CHECK 해석", () => {
  const files = (entries: Record<string, string>) => new Map(Object.entries(entries));
  const check = (list: string, head = "alter table public.metric_events add constraint metric_events_type_check") => `${head} check (type in (${list}));`;

  it("소문자 · 대문자 · 따옴표 붙은 이름 · 여러 줄 · 여분 공백을 모두 읽는다", () => {
    expect(parseLatestTypeCheck(files({ "1.sql": check("'a', 'b'") }))).toEqual(["a", "b"]);
    expect(parseLatestTypeCheck(files({ "1.sql": "ALTER TABLE public.metric_events ADD CONSTRAINT metric_events_type_check CHECK (type IN ('a', 'b', 'c'));" }))).toEqual(["a", "b", "c"]);
    expect(parseLatestTypeCheck(files({ "1.sql": 'Alter Table public.metric_events Add Constraint "Metric_Events_Type_Check" Check (Type In (\'x\'));' }))).toEqual(["x"]);
    expect(parseLatestTypeCheck(files({ "1.sql": "ALTER TABLE public.metric_events\n  ADD   CONSTRAINT\n    metric_events_type_check\n  CHECK\n(\n  type\n  IN\n  (\n 'a'\n ,\n 'b'\n)\n)" }))).toEqual(["a", "b"]);
  });

  it("파일 이름 순으로 가장 나중에 그 제약을 만지는 파일의 마지막 정의를 쓴다 (건드리지 않는 뒤 파일 · 주석 언급은 건너뛴다)", () => {
    expect(parseLatestTypeCheck(files({ "1.sql": check("'a'"), "2.sql": check("'a', 'b'"), "3.sql": "select 1;", "4.sql": "-- metric_events_type_check는 곧 바뀐다\n/* metric_events_type_check */ select 2;" }))).toEqual(["a", "b"]);
    expect(parseLatestTypeCheck(files({ "1.sql": `${check("'a'")}\n${check("'a', 'z'")}` }))).toEqual(["a", "z"]);
  });

  it("가장 나중에 만지는 파일을 해석하지 못하면 이전 목록으로 돌아가지 않고 실패한다", () => {
    const older = check("'a', 'b'");
    for (const newest of [
      "alter table public.metric_events add constraint metric_events_type_check check (type = any (array['a','b','c']));",
      "alter table public.metric_events drop constraint metric_events_type_check;",
      "alter table public.metric_events add constraint metric_events_type_check check (type in (select t from public.metric_types));",
      "alter table public.metric_events add constraint metric_events_type_check check (type in (lower('A'), 'b'));",
    ]) {
      expect(() => parseLatestTypeCheck(files({ "1.sql": older, "2.sql": newest })), newest).toThrow(/해석/);
    }
  });

  it("그 제약이 어디에도 없으면 실패한다", () => {
    expect(() => parseLatestTypeCheck(files({ "1.sql": "select 1;" }))).toThrow(/찾지 못/);
  });
});

describe("R1 최신 CHECK ↔ 등록부", () => {
  it("마지막 metric_events_type_check는 OA 전 7개 ∪ 에이전트 등록부 19개 ∪ 결제 · 키 등록부 20개와 정확히 같다", () => {
    const registry = AGENT_EVENTS.map((spec) => spec.type);
    const billing = BILLING_EVENTS.map((spec) => spec.type);
    expect(new Set(registry).size).toBe(registry.length);
    expect(new Set(billing).size).toBe(billing.length);
    expect(registry).toHaveLength(19);
    expect(billing).toHaveLength(20);
    expect(PRE_OA_TYPES).toHaveLength(7);
    // 세 묶음은 겹치지 않는다: 한 type의 집이 둘이면 카드 · 리텐션 규칙이 갈린다
    expect(new Set([...PRE_OA_TYPES, ...registry, ...billing]).size).toBe(7 + 19 + 20);
    const check = latestTypeCheck();
    expect(new Set(check).size).toBe(check.length);
    expect([...check].sort()).toEqual([...PRE_OA_TYPES, ...registry, ...billing].sort());
  });
});

describe("R2 등록부의 원천 함수 · 파일", () => {
  const sqlSources = AGENT_EVENTS.flatMap((spec) => spec.sources.flatMap((source) => (source.kind === "sql" ? [{ type: spec.type, fn: source.fn }] : [])));
  const tsSources = AGENT_EVENTS.flatMap((spec) => spec.sources.flatMap((source) => (source.kind === "ts" ? [{ type: spec.type, file: source.file }] : [])));

  it.each(sqlSources)("$type ← $fn: 최신 정의가 metric_events에 그 type을 쓴다", ({ type, fn }) => {
    const definition = latestFunctionBody(fn);
    expect(definition, `public.${fn} 정의`).not.toBeNull();
    expect(definition!.body).toMatch(/insert\s+into\s+public\.metric_events/i);
    expect(definition!.body).toContain(`'${type}'`);
  });

  it.each(tsSources)("$type ← $file: 그 파일이 type을 insert한다", ({ type, file }) => {
    const text = readFileSync(path.join(ROOT, file), "utf8");
    expect(text).toMatch(new RegExp(`type:\\s*["']${type}["']`));
  });

  it("SQL 원천 18곳과 TS 원천 2곳(합 20곳)이 등록부에 있다. 남기는 곳 없는 type은 assistant_opened 하나", () => {
    expect(sqlSources).toHaveLength(18);
    expect(tsSources).toHaveLength(2);
    expect(AGENT_EVENTS.filter((spec) => spec.sources.length === 0).map((spec) => spec.type)).toEqual(["assistant_opened"]);
  });
});

describe("R3 type마다 그 발생 지점을 부르는 시험 파일이 있다", () => {
  const testFiles = walk(
    path.join(ROOT, "tests"),
    (file) => file.endsWith(".ts"),
    (dir) => dir === path.join(ROOT, "tests/metrics"),
  ).concat(walk(path.join(ROOT, "src"), (file) => file.endsWith(".test.ts") && !file.includes("lib/metrics/")));
  const contents = new Map(testFiles.map((file) => [file, readFileSync(file, "utf8")]));

  // SQL이 남기는 type은 metric_events를 읽는 시험 파일이어야 한다 (CHECK 목록 글자만 담은 파일은 세지 않는다). TS가 남기는 type은 그 type 글자를 담은 시험 파일이면 된다
  it.each(AGENT_EVENTS.filter((spec) => spec.sources.length > 0).map((spec) => [spec.type, spec.sources.some((source) => source.kind === "sql")] as const))("%s", (type, viaSql) => {
    const hits = [...contents]
      .filter(([, text]) => quoted(type).test(text) && (!viaSql || text.includes("metric_events")))
      .map(([file]) => path.relative(ROOT, file));
    expect(hits.length, `${type}을 담은 시험 파일`).toBeGreaterThan(0);
  });
});

describe("R4 assistant_opened는 아직 남기는 곳이 없다", () => {
  it("등록부는 원천 없음 + 공백 사유를 적고, src · apple의 비시험 코드에 그 글자가 없다", () => {
    const spec = AGENT_EVENTS.find((e) => e.type === "assistant_opened");
    expect(spec).toBeDefined();
    expect(spec!.sources).toEqual([]);
    expect(spec!.gap).toBeTruthy();
    const code = [
      // 등록부와 그 type을 이름 붙여 보여 주는 화면 파일은 보내는 곳이 아니다
      ...walk(
        path.join(ROOT, "src"),
        (file) => /\.(ts|tsx)$/.test(file) && !/\.test\.tsx?$/.test(file) && !file.endsWith("lib/metrics/agents.ts") && !file.endsWith("app/admin/metrics/page.tsx"),
      ),
      ...walk(path.join(ROOT, "apple"), (file) => file.endsWith(".swift"), (dir) => /Tests$/.test(dir)),
    ];
    const found = code.filter((file) => readFileSync(file, "utf8").includes("assistant_opened")).map((file) => path.relative(ROOT, file));
    expect(found).toEqual([]);
  });
});

describe("R5 자유 글 답은 지표 행이 없다 (Q4 A)", () => {
  it("route_agent_message의 최신 정의는 answer_agent_question을 직접 부르고 metric_events를 쓰지 않는다", () => {
    const definition = latestFunctionBody("route_agent_message");
    expect(definition).not.toBeNull();
    expect(definition!.body).toMatch(/public\.answer_agent_question\s*\(/);
    expect(definition!.body).not.toMatch(/answer_agent_question_recorded/);
    expect(definition!.body).not.toMatch(/metric_events/);
  });
});

// ─── 결제 · 키 이벤트 (OA 결제 PR-A, 20261129000000): 에이전트 등록부와 따로 두는 묶음 ───
// 상태 전이 SQL 함수가 같은 트랜잭션에서 billing_emit(…)으로 남긴다(중복 막기와 한 몸 — 재전달에 두 번 세지 않는다). 읽는 카드는 후속이다(/admin/metrics 결제 카드).

describe("R2b 결제 등록부의 원천 함수", () => {
  const sqlSources = BILLING_EVENTS.flatMap((spec) => spec.sources.flatMap((source) => (source.kind === "sql" ? [{ type: spec.type, fn: source.fn }] : [])));

  it.each(sqlSources)("$type ← $fn: 최신 정의가 billing_emit(또는 metric_events insert)으로 그 type을 남긴다", ({ type, fn }) => {
    const definition = latestFunctionBody(fn);
    expect(definition, `public.${fn} 정의`).not.toBeNull();
    expect(definition!.body).toMatch(/billing_emit\s*\(|insert\s+into\s+(?:public\.)?metric_events/i);
    expect(definition!.body).toContain(`'${type}'`);
  });

  it("billing_emit은 metric_events에 쓰는 유일한 길이고, 결제 원천 함수는 TS 쪽에서 type을 insert하지 않는다", () => {
    const emit = latestFunctionBody("billing_emit");
    expect(emit).not.toBeNull();
    expect(emit!.body).toMatch(/insert\s+into\s+metric_events/i);
    const billingCode = walk(path.join(ROOT, "src/lib/billing"), (file) => file.endsWith(".ts") && !file.endsWith(".test.ts") && !file.endsWith("testing.ts"));
    const direct = billingCode.filter((file) => /from\(["']metric_events["']\)/.test(readFileSync(file, "utf8"))).map((file) => path.relative(ROOT, file));
    expect(direct).toEqual([]);
  });

  it("결제 · 키 type은 모두 남기는 곳이 있다 (ai_key 셋은 키 저장소 SQL 함수가 남긴다)", () => {
    expect(BILLING_EVENTS.filter((spec) => spec.sources.length === 0)).toEqual([]);
    expect(BILLING_EVENTS.every((spec) => !spec.gap)).toBe(true);
    const key = Object.fromEntries(BILLING_EVENTS.filter((spec) => spec.type.startsWith("ai_key_")).map((spec) => [spec.type, spec.sources.map((source) => (source.kind === "sql" ? source.fn : source.kind))]));
    expect(key).toEqual({ ai_key_saved: ["ai_key_put"], ai_key_deleted: ["ai_key_after_delete"], ai_key_revoked: ["ai_key_mark_revoked"] });
  });
});

describe("R3b 결제 type마다 그 발생 지점을 부르는 시험 파일이 있다", () => {
  const testFiles = walk(
    path.join(ROOT, "tests"),
    (file) => file.endsWith(".ts"),
    (dir) => dir === path.join(ROOT, "tests/metrics"),
  ).concat(walk(path.join(ROOT, "src"), (file) => file.endsWith(".test.ts") && !file.includes("lib/metrics/")));
  const contents = new Map(testFiles.map((file) => [file, readFileSync(file, "utf8")]));

  it.each(BILLING_EVENTS.filter((spec) => spec.sources.length > 0).map((spec) => [spec.type] as const))("%s", (type) => {
    const hits = [...contents].filter(([, text]) => quoted(type).test(text) && text.includes("metric_events")).map(([file]) => path.relative(ROOT, file));
    expect(hits.length, `${type}을 담고 metric_events를 읽는 시험 파일`).toBeGreaterThan(0);
  });
});

describe("R6 결제 type은 에이전트 카드의 '모르는 type'이 아니다", () => {
  const period = { from: new Date("2026-10-01T00:00:00Z"), to: new Date("2026-11-01T00:00:00Z") };
  it("등록부에 있는 결제 · 키 type 20개는 따로 세지 않고 에이전트 행도 만들지 않는다", () => {
    const rows = BILLING_EVENTS.map((spec, n) => ({ userId: `u${n}`, type: spec.type, at: "2026-10-10T00:00:00Z", props: {} }));
    const card = agentUsage(rows, [], period);
    expect(card.unknown).toEqual({ types: 0, events: 0 });
    expect(card.types.map((t) => t.type)).toEqual(AGENT_EVENTS.map((e) => e.type));
    expect(card.empty).toBe(true);
    expect(agentUsage([{ userId: "u", type: "billing_made_up", at: "2026-10-10T00:00:00Z", props: {} }], [], period).unknown).toEqual({ types: 1, events: 1 });
  });
});
