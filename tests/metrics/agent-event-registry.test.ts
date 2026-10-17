import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { AGENT_EVENTS, PRE_OA_TYPES } from "@/lib/metrics/agents";

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

/** 파일 이름 순으로 마지막에 나온 metric_events_type_check의 type 목록 */
function latestTypeCheck(): string[] {
  let latest: string[] | null = null;
  for (const text of migrations.values()) {
    for (const match of text.matchAll(/add constraint metric_events_type_check\s+check\s*\(\s*type\s+in\s*\(([\s\S]*?)\)\s*\)/g)) {
      latest = [...match[1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
    }
  }
  if (!latest) throw new Error("metric_events_type_check를 찾지 못했다");
  return latest;
}

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

describe("R1 최신 CHECK ↔ 등록부", () => {
  it("마지막 metric_events_type_check는 OA 전 7개 ∪ 등록부 17개와 정확히 같다", () => {
    const registry = AGENT_EVENTS.map((spec) => spec.type);
    expect(new Set(registry).size).toBe(registry.length);
    expect(registry).toHaveLength(17);
    expect(PRE_OA_TYPES).toHaveLength(7);
    const check = latestTypeCheck();
    expect(new Set(check).size).toBe(check.length);
    expect([...check].sort()).toEqual([...PRE_OA_TYPES, ...registry].sort());
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

  it("SQL 원천 17곳과 TS 원천 1곳(합 18곳)이 등록부에 있다. 남기는 곳 없는 type은 assistant_opened 하나", () => {
    expect(sqlSources).toHaveLength(17);
    expect(tsSources).toHaveLength(1);
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
