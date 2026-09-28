import { describe, expect, it } from "vitest";

import { buildHandoff, formatDate, HANDOFF_LIMITS, josa, type HandoffEvidence, type HandoffInput } from "./handoff";

// PRD 핵심 시나리오 4: 금요일 약속 → 월요일로 연장된 제안서 발송을 AI에게 넘긴다.
const meeting: HandoffEvidence = {
  quote: "청혁: 네, 금요일까지 제안서 정리해서 보내드릴게요.",
  context: null,
  role: "created",
  source: { kind: "meeting", title: "파트너사 주간 회의", occurredAt: "2025-09-22T01:00:00Z", url: "https://notion.so/meeting" },
};
const slack: HandoffEvidence = {
  quote: "김대표: 제안서는 월요일에 받아도 괜찮아요",
  context: null,
  role: "updated",
  source: { kind: "message", title: null, occurredAt: "2025-09-24T05:30:00Z", url: null },
};

const input = (over: Partial<HandoffInput["action"]> = {}, rest: Partial<HandoffInput> = {}): HandoffInput => ({
  action: {
    title: "파트너사에 제안서 발송",
    owner: "me",
    status: "open",
    due_date: "2025-09-29",
    counterpart: "김대표",
    confirm_reasons: [],
    resolution: null,
    ...over,
  },
  evidence: [slack, meeting],
  userEdits: [],
  ...rest,
});

describe("formatDate", () => {
  it("날짜와 요일 (시각은 한국 시간 날짜로)", () => {
    expect(formatDate("2025-09-29")).toBe("2025-09-29 (월)");
    expect(formatDate("2025-09-21T16:00:00Z")).toBe("2025-09-22 (월)");
  });
});

describe("josa", () => {
  it("받침 · ㄹ받침 · 숫자에 맞는 조사", () => {
    expect([josa("기한", "을"), josa("상태", "을"), josa("담당", "이"), josa("상태", "이")]).toEqual(["기한을", "상태를", "담당이", "상태가"]);
    expect([josa("2025-10-06 (월)", "으로"), josa("다른 사람", "으로"), josa("나", "으로"), josa("2025-10-02 (목)", "으로")]).toEqual([
      "2025-10-06 (월)로",
      "다른 사람으로",
      "나로",
      "2025-10-02 (목)으로",
    ]);
    expect([josa("7", "으로"), josa("3", "으로"), josa("Q4", "으로")]).toEqual(["7로", "3으로", "Q4로"]);
    expect([josa("Slack", "을"), josa("Email", "으로"), josa("Notion", "으로"), josa("Figma", "으로")]).toEqual(["Slack을", "Email로", "Notion으로", "Figma로"]);
  });
});

describe("buildHandoff", () => {
  it("합의된 내용과 근거 원문을 오래된 순으로 담는다", () => {
    const md = buildHandoff(input());
    expect(md).toContain("# 파트너사에 제안서 발송");
    expect(md).toContain("- 기한: 2025-09-29 (월)");
    expect(md).toContain("- 상대방: 김대표");
    expect(md).toContain("- 담당: 나");
    expect(md.indexOf("금요일까지")).toBeLessThan(md.indexOf("월요일에 받아도"));
    expect(md).toContain("1. 2025-09-22 (월) 회의록 「파트너사 주간 회의」\n   > 청혁: 네, 금요일까지 제안서 정리해서 보내드릴게요.\n   출처: https://notion.so/meeting");
    expect(md).toContain("2. 2025-09-24 (수) 메시지\n   > 김대표: 제안서는 월요일에 받아도 괜찮아요");
    expect(md).not.toContain("아직 확실하지 않은 것");
  });

  it("지어내지 말라는 부탁으로 끝난다", () => {
    expect(buildHandoff(input())).toMatch(/## 부탁[\s\S]*지어내지 말고[\s\S]*\n$/);
  });

  it("불확실한 것은 따로 적고, 내부용 이유(병합 확인)는 빼며 AI에게 확정처럼 쓰지 말라고 한다", () => {
    const md = buildHandoff(
      input({
        confirm_reasons: ["담당 확인", "병합 확인 (55%): 견적서 회신", "기한 확인"],
        resolution: { due: { value: "2025-09-29", risks: [{ kind: "tentative_change", claimId: "c9", value: "2025-10-06" }] } },
      }),
    );
    expect(md).toContain("## 아직 확실하지 않은 것");
    expect(md).toContain("- 내가 맡은 일인지 아직 확실하지 않습니다.");
    expect(md).toContain("- 기한이 아직 확실하지 않습니다.");
    expect(md).toContain("- 기한을 2025-10-06 (월)로 바꿀 수도 있다는 잠정적인 이야기가 있었습니다.");
    expect(md).not.toContain("병합 확인");
    expect(md).toContain("확정된 것처럼 쓰지 말아 주세요");
  });

  it("사용자가 앱에서 정한 값도 경위에 들어간다", () => {
    const md = buildHandoff(input({ due_date: "2025-10-06" }, { userEdits: [{ field: "due", value: "2025-10-06", occurredAt: "2025-09-25T00:00:00Z" }] }));
    expect(md).toContain("3. 2025-09-25 (목) 내가 직접 정함: 기한 → 2025-10-06 (월)");
  });

  it("긴 인용은 자르고, 근거가 많으면 최근 것만 남긴다", () => {
    const long = { ...meeting, quote: "가".repeat(HANDOFF_LIMITS.quoteChars + 50) };
    const many = Array.from({ length: HANDOFF_LIMITS.evidence + 3 }, (_, i) => ({
      ...slack,
      quote: `메시지 ${i}`,
      source: { ...slack.source, occurredAt: new Date(Date.UTC(2025, 8, 1 + i)).toISOString() },
    }));
    expect(buildHandoff(input({}, { evidence: [long] }))).toContain(`${"가".repeat(HANDOFF_LIMITS.quoteChars)}…`);
    const md = buildHandoff(input({}, { evidence: many }));
    expect(md).toContain("(앞선 기록 3건은 생략)");
    expect(md).not.toContain("메시지 2\n");
    expect(md).toContain("메시지 14");
  });

  it("원문 앞뒤 줄이 있으면 그 대목과 근거 구절을 함께 보여준다", () => {
    const withContext = { ...meeting, context: "\n김대표: 제안서 금요일까지 가능할까요?\n청혁: 네, 금요일까지 제안서 정리해서 보내드릴게요.\n" };
    expect(buildHandoff(input({}, { evidence: [withContext] }))).toContain(
      '   > 김대표: 제안서 금요일까지 가능할까요?\n   > 청혁: 네, 금요일까지 제안서 정리해서 보내드릴게요.\n   근거: "청혁: 네, 금요일까지 제안서 정리해서 보내드릴게요."\n   출처:',
    );
  });

  it("근거 구절은 한 줄로 줄이고 코드 울타리를 풀어 목록이 깨지지 않게 한다", () => {
    const fenced = { ...meeting, quote: "```\ncode\n```", context: "앞 줄\n```\ncode\n```" };
    const md = buildHandoff(input({}, { evidence: [fenced] }));
    expect(md).toContain('   근거: "`` code ``"');
    expect(md).not.toMatch(/^code/m);
  });

  it("닫힌 일은 불확실한 것을 묻지 않고, 읽지 않은 오래된 근거 수를 알린다", () => {
    const md = buildHandoff(input({ status: "dropped", confirm_reasons: ["담당 확인"] }, { olderEvidence: 4 }));
    expect(md).not.toContain("아직 확실하지 않은 것");
    expect(md).toContain("(앞선 기록 4건은 생략)");
  });

  it("Notion 요약처럼 깊게 들여 쓴 대목은 단계당 2칸으로 줄여 코드 블록이 되지 않게 한다", () => {
    const notion = { ...meeting, context: "[AI 요약]\n    ### 액션 아이템\n    - [ ] 제안서 발송\n        - [ ] 견적 첨부" };
    expect(buildHandoff(input({}, { evidence: [notion] }))).toContain("   > [AI 요약]\n   >   ### 액션 아이템\n   >   - [ ] 제안서 발송\n   >     - [ ] 견적 첨부");
  });

  it("여러 줄 인용도 모두 인용 표시가 붙고, 기한 · 상대가 없으면 그렇게 적는다", () => {
    const md = buildHandoff(input({ due_date: null, counterpart: null }, { evidence: [{ ...meeting, quote: "첫 줄\n\n둘째 줄" }] }));
    expect(md).toContain("   > 첫 줄\n   >\n   > 둘째 줄");
    expect(md).toContain("- 기한: 정해지지 않음");
    expect(md).not.toContain("상대방");
  });
});
