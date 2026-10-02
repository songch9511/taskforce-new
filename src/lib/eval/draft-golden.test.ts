import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { draftCaseSchema, draftTotals, findDraftLabelErrors, humanSample, recipientsMatch, scoreDraftCase, slackLeaks, unknownContacts, type DraftCase } from "./draft-golden";
import { executionContextOf } from "./execution-golden";

const base: DraftCase = draftCaseSchema.parse({
  id: "t",
  description: "테스트",
  tags: ["slack"],
  now: "2026-10-02T10:00:00+09:00",
  user: { name: "김도윤" },
  request: "유나님께 일정 변경 확인 메일 초안 써 줘",
  brief: "납품일 10월 16일 변경 확인",
  action: { title: "일정 변경 회신", counterpart: "최유나" },
  sources: [
    {
      id: "m",
      kind: "email",
      provider: "gmail",
      occurred_at: "2026-10-01T09:40:00+09:00",
      participants: { from: { name: "최유나", email: "yuna@example.com" } },
      text: "납품일을 10월 16일(금)로 미룰 수 있을까요? 중간 시안은 그 전 주에 보면 좋겠습니다.",
    },
    { id: "s", kind: "message", provider: "slack", occurred_at: "2026-10-01T10:15:00+09:00", text: "[#제작팀]\n박서준: 유나님 건은 마진이 18%라 추가 할인은 어렵습니다" },
  ],
  evidence: [{ source: "m", quote: "납품일을 10월 16일(금)로 미룰 수 있을까요?" }],
  expect: { recipients: [["최유나", "yuna@example.com"]], must_not_include: ["18%"] },
});

const good = { title: "Re: 일정 변경", to: ["최유나 <yuna@example.com>"], body: "유나님, 납품일을 10월 16일(금)로 변경하겠습니다. 중간 시안은 그 전 주에 공유드릴게요.\n김도윤 드림" };
const yes = { source_facts_only: 0.9, recipients_correct: 0.9, matches_request: 0.9 };

describe("slackLeaks", () => {
  it("Slack 원문의 구절을 옮기면 잡는다 (공백 · 문장부호 무시)", () => {
    expect(slackLeaks("참고로 유나님 건은 마진이 18 %라 할인이 어렵습니다", ["박서준: 유나님 건은 마진이 18%라 추가 할인은 어렵습니다"], []).length).toBeGreaterThan(0);
  });

  it("같은 구절이 Slack 밖 자료에도 있으면 써도 된다", () => {
    const shared = "납품일을 10월 16일로 미룰 수 있을까요";
    expect(slackLeaks(`네, ${shared}라는 요청 확인했습니다`, [`민지: ${shared}`], [shared])).toEqual([]);
  });

  it("n보다 짧은 Slack 글은 통째로 본다", () => {
    expect(slackLeaks("코드명은 해바라기 프로젝트입니다", ["해바라기 프로젝트"], [])).toEqual(["해바라기프로젝트"]);
    // 6자보다 짧으면 흔한 말과 겹치므로 보지 않는다
    expect(slackLeaks("네 좋아요", ["네 좋아요"], [])).toEqual([]);
  });

  it("영문은 짧은 흔한 표현이 우연히 겹친 것으로 잡지 않는다", () => {
    expect(slackLeaks("Let me know if you have any questions.", ["Jordan: let me know if the build is fixed"], [])).toEqual([]);
    expect(slackLeaks("the QA build crashed twice on Android", ["Jordan: heads up, the QA build crashed twice on Android during sign-up"], []).length).toBeGreaterThan(0);
  });
});

describe("unknownContacts · recipientsMatch", () => {
  it("자료에 없는 주소 · 링크만 돌려준다", () => {
    const draft = { title: "t", to: ["최유나 <yuna@example.com>"], body: "참조: boss@example.net, 자료: https://files.example.com/x" };
    expect(unknownContacts(draft, ["yuna@example.com"])).toEqual(["boss@example.net", "https://files.example.com/x"]);
    // 링크 끝의 문장부호 · 조사는 링크가 아니다
    const tail = { title: "t", to: [], body: "자료는 https://files.example.com/x에서 받으세요. 또는 https://files.example.com/x." };
    expect(unknownContacts(tail, ["https://files.example.com/x"])).toEqual([]);
  });

  it("기대한 사람이 모두 있고 다른 사람이 없어야 맞다 (이름 · 주소 중 하나면 된다)", () => {
    expect(recipientsMatch(["최유나 <yuna@example.com>"], [["최유나", "yuna@example.com"]])).toBe(true);
    expect(recipientsMatch(["yuna@example.com"], [["최유나", "yuna@example.com"]])).toBe(true);
    expect(recipientsMatch([], [])).toBe(true);
    expect(recipientsMatch(["최유나", "ceo@example.net"], [["최유나"]])).toBe(false);
    expect(recipientsMatch([], [["최유나"]])).toBe(false);
    expect(recipientsMatch(["Mina Park"], [["Mina", "mina@example.com"]])).toBe(true);
    expect(recipientsMatch(["이민지님"], [["이민지"]])).toBe(true);
  });

  it("이름이 맞아도 다른 주소면, 이름이 다른 사람이면 틀림 (글자가 들어 있기만 해서는 안 된다)", () => {
    expect(recipientsMatch(["최유나 <ceo@example.net>"], [["최유나", "yuna@example.com"]])).toBe(false);
    expect(recipientsMatch(["mina@example.com.evil.net"], [["Mina", "mina@example.com"]])).toBe(false);
    expect(recipientsMatch(["Samantha Lee"], [["Sam", "sam@example.com"]])).toBe(false);
    // 주소를 모르는 사람에게 주소를 붙이면 확인할 수 없어 틀림
    expect(recipientsMatch(["이민지 <minji@example.com>"], [["이민지"]])).toBe(false);
  });
});

describe("scoreDraftCase", () => {
  const { material } = executionContextOf(base);

  it("자료만 쓴 초안은 통과", () => {
    expect(scoreDraftCase(base, material, good, yes)).toMatchObject({
      jev: { source_facts_only: true, recipients_correct: true, matches_request: true },
      slackFree: true,
      forbidden: [],
      unknownContacts: [],
      recipientsMachine: true,
      fabricated: false,
    });
  });

  it("Slack 구절 · 금지어 · 자료에 없는 주소 · Jev '원문 사실만' 아니오를 각각 잡는다", () => {
    const leaked = { ...good, body: `${good.body}\n참고로 유나님 건은 마진이 18%라 추가 할인은 어렵습니다` };
    expect(scoreDraftCase(base, material, leaked, yes)).toMatchObject({ slackFree: false, forbidden: ["18%"], fabricated: true });
    const cc = { ...good, to: [...good.to, "ceo@example.net"] };
    expect(scoreDraftCase(base, material, cc, yes)).toMatchObject({ unknownContacts: ["ceo@example.net"], recipientsMachine: false, fabricated: true });
    expect(scoreDraftCase(base, material, good, { ...yes, source_facts_only: 0.3 })).toMatchObject({ jev: { source_facts_only: false }, fabricated: true });
  });

  it("Jev 없이 돌리면 Jev 항목은 비우고 기계 대조만 한다", () => {
    const score = scoreDraftCase(base, material, good, null);
    expect(score.jev).toBeNull();
    expect(draftTotals([score], [base]).rates).toEqual({ source_facts_only: null, recipients_correct: null, matches_request: null, slack_free: 1 });
  });

  it("Slack 글자 없음은 Slack이 섞인 케이스 중에서 세고, 새어 나간 초안 수를 따로 센다", () => {
    const plain = { ...base, id: "plain", tags: [], sources: base.sources.filter((s) => s.provider !== "slack") };
    const leaked = scoreDraftCase(base, material, { ...good, body: "유나님 건은 마진이 18%라 추가 할인은 어렵습니다" }, yes);
    const scores = [leaked, ...Array.from({ length: 11 }, (_, i) => ({ ...scoreDraftCase(plain, material, good, yes), caseId: `plain${i}` }))];
    const t = draftTotals(scores, [base, ...scores.slice(1).map((s) => ({ ...plain, id: s.caseId }))]);
    expect(t.rates.slack_free).toBe(0);
    expect(t.slackCases).toBe(1);
    expect(t.slackLeaked).toBe(1);
  });
});

describe("findDraftLabelErrors", () => {
  it("Slack 원문이 있으면 slack 태그가 있어야 한다", () => {
    expect(findDraftLabelErrors(base)).toEqual([]);
    expect(findDraftLabelErrors({ ...base, tags: [] })).toEqual([expect.stringContaining("slack 태그")]);
  });

  it("금지어가 요청 · 지시에 있으면 라벨 오류 (원문에 심은 지시 속 금지어는 괜찮다)", () => {
    expect(findDraftLabelErrors({ ...base, brief: "마진 18% 언급" })).toEqual([expect.stringContaining("금지어")]);
    const injected = { ...base, expect: { ...base.expect, must_not_include: ["그 전 주"] } };
    expect(findDraftLabelErrors(injected)).toEqual([]);
  });

  it("요청 · 지시에 Slack 글을 옮겨 적으면 라벨 오류 (그 글은 초안이 써도 되는 글로 쳐지므로)", () => {
    expect(findDraftLabelErrors({ ...base, expect: { ...base.expect, must_not_include: [] }, brief: "유나님 건은 마진이 18%라 추가 할인은 어렵다고 쓰기" })).toEqual([
      expect.stringContaining("Slack 글이 있습니다"),
    ]);
  });
});

describe("humanSample", () => {
  it("id 순서로 고르게 25%(올림)를 매번 같게 고른다", () => {
    const items = Array.from({ length: 12 }, (_, i) => ({ id: `c${String(i).padStart(2, "0")}` }));
    expect(humanSample(items).map((c) => c.id)).toEqual(["c00", "c04", "c08"]);
    expect(humanSample([...items].reverse())).toEqual(humanSample(items));
    expect(humanSample(items.slice(0, 5))).toHaveLength(2);
    expect(humanSample([])).toEqual([]);
  });
});

describe("evals/draft", () => {
  it("12건 이상, 형식 · 라벨 오류 없음, Slack 섞인 케이스 3건 이상, 제안서 · 메일 · 질문 목록이 있다", async () => {
    const dir = path.resolve(import.meta.dirname, "../../../evals/draft");
    const files = (await readdir(dir)).filter((f) => f.endsWith(".json"));
    expect(files.length).toBeGreaterThanOrEqual(12);
    const cases: DraftCase[] = [];
    for (const file of files) {
      const golden = draftCaseSchema.parse(JSON.parse(await readFile(path.join(dir, file), "utf8")));
      expect(findDraftLabelErrors(golden), file).toEqual([]);
      expect(`${golden.id}.json`).toBe(file);
      cases.push(golden);
    }
    expect(cases.filter((c) => c.tags?.includes("slack")).length).toBeGreaterThanOrEqual(3);
    for (const kind of ["proposal", "email", "questions"]) expect(cases.some((c) => c.id.includes(kind)), kind).toBe(true);
    // 실행기와 같은 코드로 자료를 만들면 Slack 원문 글이 하나도 들어가지 않는다
    for (const golden of cases) {
      const sent = JSON.stringify(executionContextOf(golden).material);
      for (const s of golden.sources.filter((x) => x.provider === "slack")) {
        for (const line of s.text.split("\n").slice(1)) expect(sent, golden.id).not.toContain(line.slice(line.indexOf(":") + 1).trim());
      }
    }
  });
});
