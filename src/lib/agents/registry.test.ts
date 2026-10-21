import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { agentCapabilitySchema } from "@/lib/api/contract";

import { AGENT_REGISTRY, attachExistingAllowed } from "./registry";

// 외부 세션 이어받기 capability (OA 외부 세션 PR2s, 계약 7장 ES-16 · 19장): Claude Code만 attach_existing, 증거는 R1 R2 R3 R8 R9 (2026-10-21, CLI 2.1.306).
// 서술자 값은 실측 증거와 함께 채운다 (런타임 계약 5장). list는 서버가 목록을 받지 않으므로 false 그대로다.

const RECORD = readFileSync(path.join(process.cwd(), "docs/rollouts/claude-code-r1-evidence.md"), "utf8");
const claude = AGENT_REGISTRY["agent:claude-code"];
const codex = AGENT_REGISTRY["agent:codex"];

describe("registry: session.attach_existing", () => {
  it("Claude Code만 true이고 list는 둘 다 false, 나머지 session 값은 그대로다", () => {
    expect(claude.session).toMatchObject({ list: false, attach_existing: true, create: true, workspace_scoped: false });
    expect(codex.session).toEqual({ list: false, attach_existing: false, create: true, workspace_scoped: true });
  });

  it("서술자는 스키마를 지나도 그대로다 (evidence 칸이 잘려 나가지 않는다)", () => {
    for (const capability of [claude, codex]) expect(agentCapabilitySchema.parse(capability)).toEqual(capability);
  });

  it("evidence가 R1 R2 R3 R8 R9 · 2026-10-21 · CLI 2.1.306 · 증거 문서를 가리킨다", () => {
    const evidence = claude.session.evidence;
    expect(evidence).toBeTypeOf("string");
    expect(evidence).toContain("docs/rollouts/claude-code-r1-evidence.md");
    expect(evidence).toContain("2026-10-21");
    expect(evidence).toContain("2.1.306");
    for (const probe of ["R1", "R2", "R3", "R8", "R9"]) expect(evidence, probe).toMatch(new RegExp(`\\b${probe}\\b`));
    // 실측하지 않은 것은 증거로 대지 않고 그렇다고 적는다
    expect(evidence).toMatch(/R4 R5 R6 R7[^.]*not claimed/);
    expect(claude.session.evidence!.length).toBeLessThanOrEqual(2000);
    // Codex는 증거가 없다
    expect(codex.session).not.toHaveProperty("evidence");
  });

  it("evidence가 대는 실측 행이 증거 문서에 있다", () => {
    for (const probe of [1, 2, 3, 8, 9]) expect(RECORD, `Resume R${probe}`).toContain(`| Resume R${probe} |`);
    expect(RECORD).toContain("2.1.306");
  });

  it("증거 문서의 새 구역에는 경로 · 세션 id · 프롬프트 글이 없다", () => {
    const block = RECORD.slice(RECORD.indexOf("## Re-run on 2.1.306"));
    expect(block.length).toBeGreaterThan(500);
    expect(block).not.toMatch(/\/Users\/|\/home\/|\/tmp\/|~\//);
    expect(block).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/);
    expect(block).not.toMatch(/\.jsonl|\.sock\b|sessions\/<?pid/);
  });
});

describe("attachExistingAllowed (route의 grade 검사)", () => {
  const on = { AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" };

  it("adapter gate가 켜져 있고 registry가 attach_existing true인 adapter만 허용한다", () => {
    expect(attachExistingAllowed("agent:claude-code", on)).toBe(true);
    expect(attachExistingAllowed("agent:codex", on)).toBe(false); // registry false
  });

  it("adapter gate가 꺼져 있으면 registry가 true여도 막는다", () => {
    expect(attachExistingAllowed("agent:claude-code", {})).toBe(false);
    expect(attachExistingAllowed("agent:claude-code", { AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "1" })).toBe(false);
    expect(attachExistingAllowed("agent:claude-code", { AGENT_ADAPTER_CODEX_ENABLED: "true" })).toBe(false);
  });

  it("registry 밖 · 객체 기본 속성 이름은 허용하지 않는다", () => {
    for (const adapter of ["agent:cursor", "", "__proto__", "constructor", "toString", "hasOwnProperty", "agent:claude-code ", "AGENT:CLAUDE-CODE"]) {
      expect(attachExistingAllowed(adapter, on), adapter).toBe(false);
    }
  });
});
