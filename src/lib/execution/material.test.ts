import { describe, expect, it } from "vitest";

import { SLACK_DISCONNECTED_QUOTE } from "@/lib/retention";

import { buildExecutionContext } from "./context";
import { materialFromRows, type SourceRow } from "./material";

// DB 행 모양 그대로 (supabase-js가 돌려주는 값: 시각은 문자열, sources에는 provider 열이 없다)

const ACTION = { title: "견적 회신", status: "open" as const, owner: "me" as const, due_date: "2026-10-09", counterpart: "박서준" };

const source = (id: string, overrides: Partial<SourceRow> = {}): SourceRow => ({
  id,
  kind: "message",
  title: null,
  raw_text: `${id} 원문: 견적서 금요일까지 회신 부탁드려요.`,
  raw_text_purged_at: null,
  raw_text_purge_reason: null,
  occurred_at: "2026-10-01T01:00:00+00:00",
  participants: null,
  external_url: null,
  external_id: null,
  connection_id: null,
  ...overrides,
});

const sent = (input: ReturnType<typeof materialFromRows>) => JSON.stringify(buildExecutionContext(input).material);

describe("materialFromRows", () => {
  it("Slack 연결에서 온 원문(링크 없음, provider는 연결 행에서)은 인용 · 본문을 모델 자료에 넣지 않는다", () => {
    const input = materialFromRows({
      action: ACTION,
      evidence: [
        { source_id: "slack-1", quote: "slack-1 원문" },
        { source_id: "paste-1", quote: "paste-1 원문" },
      ],
      sources: [source("slack-1", { connection_id: "conn-slack", external_id: "C123:1727740800.000100" }), source("paste-1")],
      connections: [{ id: "conn-slack", provider: "slack" }],
    });
    expect(input.sources.find((s) => s.id === "slack-1")?.provider).toBe("slack");
    const material = sent(input);
    expect(material).not.toContain("slack-1");
    expect(material).toContain("paste-1 원문");
    expect(buildExecutionContext(input).excluded.slack).toBe(1);
  });

  it("실행 receipt(kind execution, 연결 없이 외부 id = 단계 id)는 출처 모름으로 빼지 않고 넘겨, 자료에서는 receipt로 빼고 센다 (U2 PR7)", () => {
    const input = materialFromRows({
      action: ACTION,
      evidence: [
        { source_id: "receipt-1", quote: "초안 저장: 견적 회신 메일" },
        { source_id: "paste-1", quote: "paste-1 원문" },
      ],
      sources: [
        source("receipt-1", { kind: "execution", raw_text: "초안 저장: 견적 회신 메일", external_id: "step-uuid", external_url: "taskforce://artifacts/a1" }),
        source("paste-1"),
      ],
      connections: [],
    });
    expect(input.sources.find((s) => s.id === "receipt-1")).toMatchObject({ kind: "execution", provider: null });
    expect(input.evidence.map((e) => e.sourceId)).toEqual(["receipt-1", "paste-1"]);
    const context = buildExecutionContext(input);
    expect(context.excluded).toEqual({ slack: 0, receipts: 1, missing: 0, overSources: 0 });
    expect(sent(input)).not.toContain("초안 저장");
  });

  it("출처를 확인할 수 없는 원문은 근거째 뺀다: 연결 행을 찾지 못함 · 연결 없이 외부 id만 있음", () => {
    const input = materialFromRows({
      action: ACTION,
      evidence: [
        { source_id: "gone-conn", quote: "gone-conn 원문" },
        { source_id: "orphan", quote: "orphan 원문" },
        { source_id: "gmail-1", quote: "gmail-1 원문" },
      ],
      sources: [
        source("gone-conn", { connection_id: "conn-deleted", external_id: "x1" }),
        source("orphan", { external_id: "1727740800.000100" }),
        source("gmail-1", { connection_id: "conn-gmail", external_id: "m1" }),
      ],
      connections: [{ id: "conn-gmail", provider: "gmail" }],
    });
    expect(input.sources.map((s) => [s.id, s.provider])).toEqual([["gmail-1", "gmail"]]);
    expect(input.evidence).toEqual([{ sourceId: "gmail-1", quote: "gmail-1 원문" }]);
    const material = sent(input);
    expect(material).not.toContain("gone-conn");
    expect(material).not.toContain("orphan");
  });

  it("직접 넣은 원문(연결 · 외부 id 없음)은 provider null로 넣고, Slack 링크 · 연결을 끊어 지운 원문은 context.ts가 뺀다", () => {
    const input = materialFromRows({
      action: ACTION,
      evidence: [
        { source_id: "link", quote: "link 원문" },
        { source_id: "disconnected", quote: SLACK_DISCONNECTED_QUOTE },
        { source_id: "purged-slack", quote: "purged-slack 원문" },
      ],
      sources: [
        source("link", { external_url: "https://acme.slack.com/archives/C1/p1727740800000100" }),
        source("disconnected", { raw_text: "", raw_text_purged_at: "2026-10-01T02:00:00+00:00", raw_text_purge_reason: "disconnected" }),
        source("purged-slack", { raw_text: "", raw_text_purged_at: "2026-10-01T02:00:00+00:00", raw_text_purge_reason: "disconnected" }),
      ],
      connections: [],
    });
    expect(input.sources.map((s) => s.provider)).toEqual([null, null, null]);
    // Slack 연결을 끊어 지운 인용 자리 표시는 근거가 아니다
    expect(input.evidence.map((e) => e.sourceId)).toEqual(["link", "purged-slack"]);
    expect(buildExecutionContext(input).material.sources).toEqual([]);
  });

  it("보관 기간이 지나 지운 원문은 글 없이(저장된 구절만), 관련자 · 시각은 DB 값에서", () => {
    const input = materialFromRows({
      action: ACTION,
      evidence: [{ source_id: "old", quote: "견적서 금요일까지 회신 부탁드려요" }],
      sources: [
        source("old", {
          raw_text: "",
          raw_text_purged_at: "2026-09-01T00:00:00+00:00",
          participants: { from: { name: "박서준", email: "seojun@example.com" } },
        }),
      ],
      connections: [],
    });
    expect(input.sources[0]).toMatchObject({ text: null, purgeReason: "retention", participants: { from: { name: "박서준", email: "seojun@example.com" } } });
    expect(input.sources[0].occurredAt?.toISOString()).toBe("2026-10-01T01:00:00.000Z");
    expect(buildExecutionContext(input).material.sources[0]).toMatchObject({ excerpts: ["견적서 금요일까지 회신 부탁드려요"], people: ["박서준 <seojun@example.com>"] });
    expect(input.action).toEqual(ACTION);
  });

  it("형식이 맞지 않는 관련자는 버린다 (원문은 그대로)", () => {
    const input = materialFromRows({
      action: ACTION,
      evidence: [{ source_id: "s", quote: "s 원문" }],
      sources: [source("s", { participants: { from: { email: "not-an-email" } } })],
      connections: [],
    });
    expect(input.sources[0].participants).toBeNull();
  });
});
