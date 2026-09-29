import { describe, expect, it } from "vitest";

import type { ActionCandidate } from "./extract";
import { verifyCandidates } from "./verify";

const source = {
  text: "김대표: 제안서 보고 싶어요.\n나: 네, 금요일까지 제안서 보내드릴게요.\n나: 회의록은 다음 주 초에 정리할게요.",
  occurredAt: new Date("2025-09-22T10:00:00+09:00"),
};

const candidate = (extra: Partial<ActionCandidate>): ActionCandidate => ({
  signal: "commitment",
  title: "제안서 발송",
  quote: "금요일까지 제안서 보내드릴게요",
  owner: "me",
  owner_confidence: 0.9,
  counterpart: null,
  due_text: "금요일까지",
  due: "2025-09-26",
  due_confidence: 0.9,
  rationale: "",
  ...extra,
});

describe("verifyCandidates", () => {
  it("원문에 없는 인용은 버린다", () => {
    const result = verifyCandidates([candidate({ quote: "월요일까지 제안서 보내드릴게요" })], source);
    expect(result.kept).toEqual([]);
    expect(result.dropped.map((d) => d.reason)).toEqual(["QUOTE_NOT_FOUND"]);
  });

  it("코드 계산과 같은 기한은 그대로 둔다", () => {
    expect(verifyCandidates([candidate({})], source).kept[0]).toMatchObject({ due: "2025-09-26", due_check: "match" });
  });

  it("모델이 요일을 틀리면 코드 값으로 바꾸고 원래 값을 남긴다", () => {
    const kept = verifyCandidates([candidate({ due: "2025-09-27" })], source).kept[0];
    expect(kept).toMatchObject({ due: "2025-09-26", model_due: "2025-09-27", due_check: "corrected" });
  });

  it("모델이 날짜를 못 냈어도 코드가 계산할 수 있으면 채운다", () => {
    expect(verifyCandidates([candidate({ due: null })], source).kept[0]).toMatchObject({ due: "2025-09-26", due_check: "corrected" });
  });

  it("코드가 모르는 표현이면 모델 값을 그대로 둔다", () => {
    const kept = verifyCandidates(
      [candidate({ quote: "회의록은 다음 주 초에 정리할게요", due_text: "다음 주 초", due: null })],
      source,
    ).kept[0];
    expect(kept).toMatchObject({ due: null, due_check: "unresolved" });
  });

  it("기한 표현이 없으면 none", () => {
    expect(verifyCandidates([candidate({ due_text: null, due: null })], source).kept[0].due_check).toBe("none");
  });

  describe("메일에 인용된 옛 메일", () => {
    const mail = (fresh: string) => ({
      text: `제목: Re: Security questionnaire\n\n${fresh}\n\nOn Thu, Oct 8, 2026 at 4:05 PM Alex Kim <alex@lumenfield.example> wrote:\n\n> Sure, I'll send the completed questionnaire by Monday.\n>\n> On Thu, Oct 8, 2026 at 3:20 PM Morgan Tate <morgan@quillstone.example> wrote:\n>\n>> Could you send the completed security questionnaire by Monday?`,
      occurredAt: new Date("2026-10-12T09:15:00+09:00"),
      kind: "email",
      fromConnector: true,
    });
    const commitment = (quote: string) => candidate({ quote, due_text: null, due: null });

    it("인용된 옛 메일에만 있는 구절은 버린다 (내 옛 약속도, 상대의 옛 요청도)", () => {
      const source = mail("Thanks, Morgan! That helps a lot.");
      const result = verifyCandidates(
        [commitment("Sure, I'll send the completed questionnaire by Monday."), commitment("Could you send the completed security questionnaire by Monday?")],
        source,
      );
      expect(result.kept).toEqual([]);
      expect(result.dropped.map((d) => d.reason)).toEqual(["QUOTED_HISTORY", "QUOTED_HISTORY"]);
    });

    it("인용 위에 새로 쓴 글은 아무리 짧아도 남는다", () => {
      const source = mail("Sure, I'll send it by Monday.");
      const result = verifyCandidates([commitment("Sure, I'll send it by Monday.")], source);
      expect(result.kept).toHaveLength(1);
      expect(result.dropped).toEqual([]);
    });

    it("새 글에도 있는 구절이면 남긴다 (인용에도 같은 말이 있어도)", () => {
      const source = mail("Sure, I'll send the completed questionnaire by Monday.");
      expect(verifyCandidates([commitment("Sure, I'll send the completed questionnaire by Monday.")], source).kept).toHaveLength(1);
    });

    it('"..."로 이은 인용은 조각 하나라도 새 글에 있으면 남긴다 (새 글과 인용에 걸친 인용)', () => {
      const source = mail("Sure, will do.");
      expect(verifyCandidates([commitment("Sure, will do ... Could you send the completed security questionnaire by Monday?")], source).kept).toHaveLength(1);
      // 조각이 모두 인용 속에만 있으면 버린다
      const onlyOld = commitment("Sure, I'll send the completed questionnaire ... Could you send the completed security questionnaire by Monday?");
      expect(verifyCandidates([onlyOld], source).dropped.map((d) => d.reason)).toEqual(["QUOTED_HISTORY"]);
    });

    it("원문에 없는 인용은 이유가 그대로 QUOTE_NOT_FOUND", () => {
      const result = verifyCandidates([commitment("I will never appear")], mail("Thanks!"));
      expect(result.dropped.map((d) => d.reason)).toEqual(["QUOTE_NOT_FOUND"]);
    });

    it("직접 붙여 넣은 메일(연결로 가져오지 않음)이면 인용된 옛 메일 속 후보도 남긴다 (옛 메일이 따로 들어온 적이 없다)", () => {
      const quoted = commitment("Sure, I'll send the completed questionnaire by Monday.");
      const pasted = { ...mail("Thanks!"), fromConnector: undefined };
      expect(verifyCandidates([quoted], pasted).kept).toHaveLength(1);
      expect(verifyCandidates([quoted], { ...pasted, fromConnector: false }).kept).toHaveLength(1);
      // 같은 메일이라도 연결로 가져왔으면 버린다
      expect(verifyCandidates([quoted], { ...pasted, fromConnector: true }).dropped.map((d) => d.reason)).toEqual(["QUOTED_HISTORY"]);
    });

    it("메일이 아니거나 종류를 모르면 이 규칙을 쓰지 않는다 (사용자가 직접 고른 구절 등)", () => {
      const quoted = commitment("Sure, I'll send the completed questionnaire by Monday.");
      expect(verifyCandidates([quoted], { ...mail("Thanks!"), kind: "meeting" }).kept).toHaveLength(1);
      expect(verifyCandidates([quoted], { ...mail("Thanks!"), kind: undefined }).kept).toHaveLength(1);
    });

    it("인용이 없는 메일은 그대로", () => {
      const plain = { text: "제목: 일정\n\n금요일까지 제안서 보내드릴게요.", occurredAt: new Date("2025-09-22T10:00:00+09:00"), kind: "email", fromConnector: true };
      expect(verifyCandidates([candidate({})], plain).kept).toHaveLength(1);
    });
  });
});
