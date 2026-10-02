import { describe, expect, it } from "vitest";

import { buildExecutionContext, isSlackSource, type ExecutionContextInput, type ExecutionSource } from "./context";

const action = { title: "회의 후속 메일", status: "open" as const, owner: "me" as const, due_date: "2026-10-05", counterpart: "이민지" };

const source = (over: Partial<ExecutionSource> & Pick<ExecutionSource, "id" | "text">): ExecutionSource => ({
  kind: "email",
  title: null,
  occurredAt: new Date("2026-10-01T01:00:00Z"),
  provider: "gmail",
  purgeReason: null,
  participants: null,
  ...over,
});

const slackText = "[#제작팀]\n박서준: 마진이 18%라 할인은 어렵습니다\n김도윤: 일정 변경은 제가 회신할게요";

const input: ExecutionContextInput = {
  action,
  sources: [
    source({
      id: "mail",
      title: "일정 변경 요청",
      text: "제목: 일정 변경 요청\n\n안녕하세요.\n납품일을 10월 16일로 미룰 수 있을까요?\n중간 시안은 그 전 주에 보면 좋겠습니다.\n감사합니다.",
      participants: { from: { name: "이민지", email: "minji@example.com" }, to: [{ name: "김도윤", email: "doyun@example.com" }] },
    }),
    source({ id: "slack", kind: "message", provider: "slack", title: "#제작팀", text: slackText }),
    // Slack 연결을 끊어 글을 지운 원문: 연결 행이 지워져 provider가 null이어도 Slack이다
    source({ id: "purged", kind: "message", provider: null, purgeReason: "disconnected", title: "Slack", text: null }),
  ],
  evidence: [
    { sourceId: "mail", quote: "납품일을 10월 16일로 미룰 수 있을까요?" },
    { sourceId: "slack", quote: "일정 변경은 제가 회신할게요" },
    { sourceId: "purged", quote: "Slack 연결을 끊어 지웠어요" },
  ],
};

describe("buildExecutionContext", () => {
  it("Slack 원문의 인용 · 본문 · 관련자는 하나도 넣지 않는다", () => {
    const context = buildExecutionContext(input);
    expect(context.excluded).toEqual({ slack: 2, receipts: 0, missing: 0, overSources: 0 });
    expect(context.material.sources).toHaveLength(1);
    const sent = JSON.stringify(context.material);
    for (const word of ["18%", "마진", "제작팀", "박서준", "제가 회신할게요", "Slack 연결을 끊어"]) expect(sent).not.toContain(word);
  });

  it("Slack 밖 원문은 근거 구절 앞뒤 발췌와 관련자를 번호로 넣는다 (내부 id는 넣지 않는다)", () => {
    const { material } = buildExecutionContext(input);
    expect(material.action).toEqual({ title: "회의 후속 메일", status: "open", owner: "me", due: "2026-10-05", counterpart: "이민지" });
    expect(material.sources[0]).toMatchObject({
      id: "S1",
      kind: "email",
      title: "일정 변경 요청",
      date: "2026-10-01",
      people: ["이민지 <minji@example.com>", "김도윤 <doyun@example.com>"],
    });
    expect(material.sources[0].excerpts[0]).toContain("납품일을 10월 16일로 미룰 수 있을까요?");
    expect(material.sources[0].excerpts[0]).toContain("그 전 주에 보면");
    expect(JSON.stringify(material)).not.toContain('"mail"');
  });

  it("보관 기간이 지나 글이 지워진 원문은 저장된 근거 구절만 보낸다 (null이든 DB의 빈 글이든)", () => {
    for (const text of [null, ""]) {
      const { material } = buildExecutionContext({
        action,
        sources: [source({ id: "old", purgeReason: "retention", text })],
        evidence: [{ sourceId: "old", quote: "금요일까지 보내드릴게요" }],
      });
      expect(material.sources[0].excerpts).toEqual(["금요일까지 보내드릴게요"]);
    }
  });

  it("원문 수 상한을 넘은 원문은 빼고 센다", () => {
    const many = Array.from({ length: 8 }, (_, i) => source({ id: `m${i}`, text: `근거 ${i}번 구절입니다` }));
    const context = buildExecutionContext({ action, sources: many, evidence: many.map((m, i) => ({ sourceId: m.id, quote: `근거 ${i}번 구절입니다` })) });
    expect(context.material.sources).toHaveLength(6);
    expect(context.excluded.overSources).toBe(2);
  });

  it("없는 원문 · 원문에서 찾을 수 없는 근거는 빼고 센다", () => {
    const context = buildExecutionContext({
      action,
      sources: [source({ id: "a", text: "전혀 다른 글" })],
      evidence: [
        { sourceId: "nowhere", quote: "x" },
        { sourceId: "a", quote: "원문에 없는 구절" },
      ],
    });
    expect(context.material.sources).toEqual([]);
    expect(context.excluded).toEqual({ slack: 0, receipts: 0, missing: 2, overSources: 0 });
  });

  it("실행 receipt(앞선 초안의 기록)는 원문이 아니라 넣지 않는다 (U2 PR7)", () => {
    const context = buildExecutionContext({
      action,
      sources: [
        source({ id: "mail", text: "납품일을 10월 16일로 미룰 수 있을까요?" }),
        source({ id: "receipt", kind: "execution", provider: null, title: "일정 변경 회신", text: "초안 저장: 일정 변경 회신", externalUrl: "taskforce://artifacts/a1" }),
      ],
      evidence: [
        { sourceId: "mail", quote: "납품일을 10월 16일로 미룰 수 있을까요?" },
        { sourceId: "receipt", quote: "초안 저장: 일정 변경 회신" },
      ],
    });
    expect(context.excluded).toEqual({ slack: 0, receipts: 1, missing: 0, overSources: 0 });
    expect(context.material.sources.map((s) => s.kind)).toEqual(["email"]);
    expect(JSON.stringify(context.material)).not.toContain("초안 저장");
  });

  it("같은 원문의 근거는 한 원문 아래 겹치지 않는 발췌로 모은다", () => {
    const { material } = buildExecutionContext({
      action,
      sources: [source({ id: "a", text: "첫 줄\n둘째 줄 약속\n셋째 줄" })],
      evidence: [
        { sourceId: "a", quote: "둘째 줄 약속" },
        { sourceId: "a", quote: "셋째 줄" },
      ],
    });
    expect(material.sources).toHaveLength(1);
    expect(material.sources[0].excerpts).toEqual(["첫 줄\n둘째 줄 약속\n셋째 줄"]);
  });
});

describe("isSlackSource", () => {
  it("연결이 Slack이거나 Slack 연결을 끊어 지운 원문", () => {
    expect(isSlackSource({ provider: "slack", purgeReason: null })).toBe(true);
    expect(isSlackSource({ provider: null, purgeReason: "disconnected" })).toBe(true);
    expect(isSlackSource({ provider: "gmail", purgeReason: "retention" })).toBe(false);
    expect(isSlackSource({ provider: null, purgeReason: null })).toBe(false);
  });

  it("연결 정보가 모두 비어도 링크가 Slack 메시지면 Slack 원문으로 본다", () => {
    expect(isSlackSource({ provider: null, purgeReason: null, externalUrl: "https://acme.slack.com/archives/C01/p1700000000000100" })).toBe(true);
    expect(isSlackSource({ provider: null, purgeReason: null, externalUrl: "https://slack.com/archives/C01" })).toBe(true);
    expect(isSlackSource({ provider: null, purgeReason: null, externalUrl: "https://notslack.com/x" })).toBe(false);
    expect(isSlackSource({ provider: null, purgeReason: null, externalUrl: "not a url" })).toBe(false);
  });
});
