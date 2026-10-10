import { describe, expect, it } from "vitest";

import { buildContextBundle, type ContextBundleInput } from "./bundle";
import { bundleIsStale } from "./contexts";
import type { MemoryLike } from "./memory";

// 맥락 묶음 (아키텍처 6.3, 런타임 계약 5장): 넣는 것 · 빼는 것, manifest는 id만, 기억은 권한이 되지 않는다(I04 · I11).

const CONTEXT = "aaaaaaaa-0000-4000-8000-000000000001";
const OTHER_CONTEXT = "aaaaaaaa-0000-4000-8000-000000000002";
const PERSON = "cccccccc-0000-4000-8000-000000000001";
const NAMELESS = "cccccccc-0000-4000-8000-000000000002";
const [NOTION, LOST, PURGED, SLACK] = [1, 2, 3, 4].map((i) => `dddddddd-0000-4000-8000-00000000000${i}`);
const NOW = new Date("2026-10-10T00:00:00Z");

let n = 0;
const memory = (overrides: Partial<MemoryLike>): MemoryLike => {
  n += 1;
  return {
    id: `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`,
    kind: "fact",
    scope_kind: "context",
    context_id: CONTEXT,
    action_id: null,
    person_id: null,
    agent_adapter: null,
    subject: null,
    statement: `기억 ${n}`,
    origin: "explicit",
    source_ref: null,
    observed_at: "2026-10-01T00:00:00Z",
    valid_from: null,
    valid_until: null,
    superseded_at: null,
    revoked_at: null,
    source_purged: false,
    ...overrides,
  };
};

const source = (id: string, overrides: Partial<ContextBundleInput["sources"][number]> = {}) => ({
  id,
  provider: "notion",
  purged: false,
  purgeReason: null,
  accessLost: false,
  externalUrl: null,
  ...overrides,
});

function input(overrides: Partial<ContextBundleInput> = {}): ContextBundleInput {
  return {
    context: { id: CONTEXT, context_version: 7 },
    me: { display_name: "Daniel", emails: ["me@example.com"] },
    memory: [
      memory({ id: "m-keep", statement: "디자인 확정 뒤 개발 시작", kind: "condition" }),
      memory({ id: "m-global", scope_kind: "global", context_id: null, statement: "금요일 배포", subject: "deploy day" }),
      memory({ id: "m-override", statement: "이 프로젝트는 목요일 배포", subject: "deploy day" }),
      memory({ id: "m-other", context_id: OTHER_CONTEXT, statement: "다른 프로젝트의 비밀" }),
      memory({ id: "m-inferred", origin: "inferred", statement: "추정" }),
      memory({ id: "m-revoked", revoked_at: "2026-10-05T00:00:00Z", statement: "잊은 것" }),
      memory({ id: "m-superseded", superseded_at: "2026-10-05T00:00:00Z", statement: "정정된 것" }),
      memory({ id: "m-purged", origin: "observed", statement: "", source_purged: true, source_ref: { source_id: PURGED } }),
      memory({ id: "m-lost", origin: "observed", statement: "잃은 자료에서", source_ref: { source_id: LOST } }),
      memory({ id: "m-slack", origin: "observed", statement: "슬랙에서", source_ref: { source_id: SLACK } }),
      memory({ id: "m-observed", origin: "observed", statement: "노션에서", source_ref: { source_id: NOTION, quote: "원문 인용" } }),
      memory({ id: "m-expired", statement: "지난 조건", valid_until: "2026-10-01T00:00:00Z" }),
      memory({ id: "m-role", scope_kind: "counterpart", context_id: null, person_id: PERSON, kind: "relationship", statement: "결정권자" }),
    ],
    people: [
      { id: PERSON, display_name: "지훈" },
      { id: NAMELESS, display_name: null },
    ],
    chunks: [
      { id: "c-notion", source_id: NOTION, source_revision: "v2", seq: 0, text: "노션 조각" },
      { id: "c-lost", source_id: LOST, source_revision: "v1", seq: 0, text: "잃은 조각" },
      { id: "c-slack", source_id: SLACK, source_revision: "1.0", seq: 0, text: "슬랙 조각" },
      { id: "c-purged", source_id: PURGED, source_revision: "v1", seq: 0, text: "지운 조각" },
    ],
    sources: [
      source(NOTION),
      source(LOST, { accessLost: true }),
      source(SLACK, { provider: "slack", externalUrl: "https://acme.slack.com/archives/C1/p1" }),
      source(PURGED, { purged: true, purgeReason: "retention" }),
    ],
    now: NOW,
    ...overrides,
  };
}

describe("buildContextBundle", () => {
  it("모양: 범위 · version · 나 · 기억 · 사람 · 자료만 있고 실행 모드 · 대상 · 예산 · 권한은 없다 (I04 · I11)", () => {
    const { bundle } = buildContextBundle(input());
    expect(Object.keys(bundle).sort()).toEqual(["context_id", "context_version", "identity", "materials", "memory", "people"]);
    expect(bundle).toMatchObject({ context_id: CONTEXT, context_version: 7, identity: { me: { display_name: "Daniel", emails: ["me@example.com"] } } });
    expect(JSON.stringify(bundle)).not.toMatch(/permission|mode|budget|policy|approval/);
    expect(Object.keys(bundle.memory[0]).sort()).toEqual(["id", "kind", "observed_at", "origin", "statement"]);
  });

  it("기억: 지금 범위의 쓸 수 있는 것만, 같은 사실은 범위 예외가 이긴다. 추정 · 다른 범위 · 잊음 · 정정 · 지움 · 잃은 원문 · Slack · 유효 구간 밖은 뺀다", () => {
    const { bundle } = buildContextBundle(input());
    expect(bundle.memory.map((m) => m.id).sort()).toEqual(["m-keep", "m-observed", "m-override", "m-role"].sort());
    expect(bundle.memory.find((m) => m.id === "m-observed")).toEqual({
      id: "m-observed",
      kind: "fact",
      statement: "노션에서",
      origin: "observed",
      observed_at: "2026-10-01T00:00:00.000Z",
    });
    // All work(범위 없음)에서는 전체 기본값이 나온다
    const all = buildContextBundle(input({ context: null })).bundle;
    expect(all.memory.map((m) => m.id).sort()).toEqual(["m-global", "m-role"]);
    expect(all).toMatchObject({ context_id: null, context_version: null });
  });

  it("사람: 이름이 있는 사람만, 이메일 없이, 역할은 그 사람의 relationship 기억", () => {
    const { bundle } = buildContextBundle(input());
    expect(bundle.people).toEqual([{ id: PERSON, display_name: "지훈", role: "결정권자" }]);
    expect(JSON.stringify(bundle.people)).not.toMatch(/@/);
  });

  it("역할: 상대마다 자기 relationship 기억 (같은 주제여도 사람이 다르면 따로), 앱이 보낸 대문자 id도 맞춘다", () => {
    const P2 = "cccccccc-0000-4000-8000-000000000003";
    const roles = [
      memory({ id: "r1", scope_kind: "counterpart", context_id: null, person_id: PERSON, kind: "relationship", subject: "role", statement: "결정권자" }),
      memory({ id: "r2", scope_kind: "counterpart", context_id: null, person_id: P2, kind: "relationship", subject: "role", statement: "실무자" }),
    ];
    const { bundle } = buildContextBundle(input({ memory: roles, people: [{ id: PERSON.toUpperCase(), display_name: "지훈" }, { id: P2, display_name: "미나" }] }));
    expect(bundle.people).toEqual([
      { id: PERSON.toUpperCase(), display_name: "지훈", role: "결정권자" },
      { id: P2, display_name: "미나", role: "실무자" },
    ]);
  });

  it("자료: 글이 남고 접근 가능하고 Slack이 아닌 원문의 조각만 (T1)", () => {
    const { bundle } = buildContextBundle(input());
    expect(bundle.materials).toEqual([{ ref: `source:${NOTION}#0`, source_id: NOTION, version: "v2", tier: "T1", text: "노션 조각" }]);
  });

  it("상태를 모르는 원문(다른 사용자 · 지워진 원문)의 조각 · observed 기억은 넣지 않는다 (사용자가 저장한 explicit은 넣는다)", () => {
    const UNKNOWN = "dddddddd-0000-4000-8000-000000000009";
    const { bundle } = buildContextBundle(
      input({
        memory: [
          memory({ id: "m-unknown", origin: "observed", statement: "모르는 원문에서", source_ref: { source_id: UNKNOWN } }),
          memory({ id: "m-said", statement: "내가 저장", source_ref: { source_id: UNKNOWN } }),
        ],
        chunks: [{ id: "c-unknown", source_id: UNKNOWN, source_revision: "v1", seq: 0, text: "모르는 조각" }],
      }),
    );
    expect(bundle.memory.map((m) => m.id)).toEqual(["m-said"]);
    expect(bundle.materials).toEqual([]);
  });

  it("manifest는 넣은 것의 id만 (글 없음). hash는 같은 내용이면 같고 내용이 바뀌면 다르다", () => {
    const built = buildContextBundle(input());
    expect(built.manifest).toEqual({
      context_id: CONTEXT,
      context_version: 7,
      memory_item_ids: built.bundle.memory.map((m) => m.id),
      person_ids: [PERSON],
      source_ids: [NOTION],
      chunk_ids: ["c-notion"],
    });
    const text = JSON.stringify(built.manifest);
    for (const fragment of ["디자인", "노션", "지훈", "결정권자", "me@example.com"]) expect(text).not.toContain(fragment);
    expect(buildContextBundle(input()).hash).toBe(built.hash);
    expect(buildContextBundle(input({ context: { id: CONTEXT, context_version: 8 } })).hash).not.toBe(built.hash);
  });

  it("(e) 사용자가 기억을 지우거나 잊으면 다음 묶음에서 빠지고, 이미 만든 묶음의 manifest(id만)는 그대로다. version이 오르면 옛 묶음은 stale 후보", () => {
    const first = buildContextBundle(input());
    const forgotten = input().memory.map((m) => (m.id === "m-keep" ? { ...m, revoked_at: "2026-10-09T00:00:00Z" } : m));
    const second = buildContextBundle(input({ memory: forgotten, context: { id: CONTEXT, context_version: 8 } }));
    expect(second.manifest.memory_item_ids).not.toContain("m-keep");
    expect(first.manifest.memory_item_ids).toContain("m-keep");
    expect(bundleIsStale(first.manifest.context_version, 8)).toBe(true);
    expect(bundleIsStale(8, 8)).toBe(false);
    expect(bundleIsStale(null, 8)).toBe(false);
  });

  it("상한: 기억 · 자료 수를 넘기지 않는다", () => {
    const many = Array.from({ length: 50 }, (_, i) => memory({ id: `bulk-${i}`, statement: `기억 ${i}` }));
    const chunks = Array.from({ length: 20 }, (_, i) => ({ id: `chunk-${i}`, source_id: NOTION, source_revision: "v2", seq: i, text: `조각 ${i}` }));
    const { bundle, manifest } = buildContextBundle(input({ memory: many, chunks, limits: { memory: 5, materials: 3 } }));
    expect(bundle.memory).toHaveLength(5);
    expect(bundle.materials).toHaveLength(3);
    expect(manifest.chunk_ids).toEqual(["chunk-0", "chunk-1", "chunk-2"]);
  });
});
