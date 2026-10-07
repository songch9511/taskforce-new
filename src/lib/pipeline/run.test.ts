import { describe, expect, it, vi } from "vitest";

import type { JevDecision } from "@/lib/ai/jev";
import { DOCUMENT_JUDGE_PROMPT_VERSION, MEETING_JUDGE_PROMPT_VERSION, WRITTEN_BY_ME_DOCUMENT_PROMPT_VERSION } from "@/lib/ai/prompts/judge";
import { EMBEDDING_DIMENSIONS } from "@/lib/ai/embed";
import { projectAction } from "@/lib/actions/project";
import { pageToItem } from "@/lib/connectors/notion/map";
import type { NotionPage } from "@/lib/connectors/notion/api";

import type { CompleteJson } from "./extract";
import type { Decide } from "./judge";
import { InMemoryActionStore, mergeJudged } from "./merge";
import { resolveAction } from "./resolve";
import { runPipeline } from "./run";

const input = {
  text: "김대표: 제안서 보고 싶어요.\n나: 네, 금요일까지 제안서 보내드릴게요.\n김대표: 견적서는 박팀장이 드릴게요.",
  kind: "meeting" as const,
  occurredAt: new Date("2025-09-22T10:00:00+09:00"),
  identity: { name: "나", aliases: [], emails: [] },
};

const raw = (quote: string, due: string | null = null) => ({
  signal: "commitment",
  rationale: "",
  title: quote,
  quote,
  owner: "me",
  owner_confidence: 0.9,
  counterpart: null,
  due_text: due ? "금요일까지" : null,
  due,
  due_confidence: due ? 0.9 : null,
});

const complete = (async () => ({
  model: "test/llm",
  usage: { prompt_tokens: 1, completion_tokens: 1, cost: 0.001 },
  data: {
    candidates: [
      raw("금요일까지 제안서 보내드릴게요", "2025-09-27"), // 요일을 틀림 → 코드가 고친다
      raw("견적서는 박팀장이 드릴게요"),
      raw("월요일에 미팅 잡을게요"), // 원문에 없음 → 버린다
    ],
  },
})) as CompleteJson;

function answers(my: number): JevDecision["answers"] {
  return {
    is_my_commitment: { type: "noul", noul: my },
    is_actionable: { type: "noul", noul: 0.95 },
    already_done: { type: "noul", noul: 0.05 },
    certainty: { type: "choice", choice: "firm", probabilities: {} },
    statement_certainty: { type: "choice", choice: "firm", probabilities: {} },
    speaker_role: { type: "choice", choice: "me", probabilities: {} },
    directness: { type: "choice", choice: "first_hand", probabilities: {} },
    audience: { type: "choice", choice: "shared", probabilities: {} },
    meeting_owner: { type: "choice", choice: "user", probabilities: { user: 0.95 } },
    document_owner: { type: "choice", choice: "user", probabilities: { user: 0.95 } },
  };
}

const decide: Decide = async (request) => {
  const quote = (request.state as { candidate: { quote: string } }).candidate.quote;
  return {
    model: "test/jev",
    answers: {
      ...answers(quote.includes("박팀장") ? 0.1 : 0.95),
      ...(quote.includes("박팀장") ? { meeting_owner: { type: "choice", choice: "someone_else", probabilities: { someone_else: 0.95 } } } : {}),
    },
    usage: { input_tokens: 1, cost: 0.0001 },
  };
};

describe("명시된 다른 담당자 — 추출부터 저장까지", () => {
  it.each(["commitment", "update", "completion", "cancellation"])("%s를 내 할 일로 만들거나 기존 할 일에 병합하지 않는다", async (signal) => {
    const task = "PR 전부 머지 후 현재 데브 브랜치 업데이트";
    const identity = { name: "다니엘", aliases: [], emails: [] };
    const store = new InMemoryActionStore();
    const mergeDeps = {
      embed: vi.fn(async () => [[1, 0]]),
      decide: vi.fn<Decide>(async () => { throw new Error("다른 담당자 업무는 매칭까지 도달하면 안 된다"); }),
      newId: (() => { let id = 0; return () => `claim-${++id}`; })(),
    };
    const extract = (signal: string) => (async () => ({
      model: "test/llm", data: { candidates: [{ ...raw(task), signal }] },
    })) as CompleteJson;
    const judge: Decide = async () => ({ model: "test/jev", answers: answers(0.95) });
    const selfSource = { ...input, identity, kind: "doc" as const, text: `다니엘님 ${task}`, writtenByMe: true };
    const own = await runPipeline(selfSource, { complete: extract("commitment"), decide: judge });
    await mergeJudged(store, own.judged, { ...selfSource, id: "mine" }, identity, mergeDeps);
    expect(store.all()).toHaveLength(1);
    const before = JSON.stringify(store.all());
    mergeDeps.embed.mockClear();

    const otherSource = { ...selfSource, text: `준혁님 ${task}` };
    const other = await runPipeline(otherSource, { complete: extract(signal), decide: judge });
    expect(other.summary).toMatchObject({ auto: 0, confirm: 0, reject: 1 });
    // 빈 목록과 기존 내 업무가 있는 목록 양쪽 모두 보호한다.
    for (const target of [new InMemoryActionStore(), store]) {
      const outcome = await mergeJudged(target, other.judged, { ...otherSource, id: "other" }, identity, mergeDeps);
      expect(outcome).toMatchObject([{ relation: "rejected", actionId: null }]);
    }
    expect(JSON.stringify(store.all())).toBe(before);
    expect(mergeDeps.embed).not.toHaveBeenCalled();
    expect(mergeDeps.decide).not.toHaveBeenCalled();
  });
});

describe("runPipeline", () => {
  it("추출 → 기계 검증 → Jev 판정을 거쳐 후보와 요약을 돌려준다", async () => {
    const result = await runPipeline(input, { complete, decide });

    expect(result.judged.map((j) => [j.candidate.quote, j.judge.decision])).toEqual([
      ["금요일까지 제안서 보내드릴게요", "auto"],
      ["견적서는 박팀장이 드릴게요", "reject"],
    ]);
    expect(result.judged[0].candidate).toMatchObject({ due: "2025-09-26", due_check: "corrected" });
    expect(result.summary).toMatchObject({
      extracted: 3,
      dropped: 1,
      auto: 1,
      confirm: 0,
      reject: 1,
      dueCorrected: 1,
      models: { extract: "test/llm", judge: "test/jev" },
    });
    expect(result.summary.cost).toBeCloseTo(0.0012);
  });

  it("사용자와 연결되지 않은 Notion 회의 액션은 새 Action으로 만들지 않는다", async () => {
    const person = (id: string, name: string) => ({ object: "user" as const, id, name, type: "person", person: {} });
    const page: NotionPage = {
      object: "page",
      id: "notion-meeting-1",
      url: "https://www.notion.so/notion-meeting-1",
      created_time: "2026-10-06T05:00:00.000Z",
      last_edited_time: "2026-10-06T05:10:00.000Z",
      parent: { type: "data_source_id" },
      created_by: { id: "notion-user" },
      properties: {
        Name: { type: "title", title: [{ plain_text: "Q3 Launch Retrospective" }] },
        Attendees: { type: "people", people: [person("maya", "Maya Chen"), person("sam", "Sam Rivera")] },
      },
    };
    const notionItem = pageToItem(
      page,
      "<meeting-notes><summary>\n- [ ] Share usability test results by Thursday\n- [ ] Update signup form copy\n- [ ] Prepare launch FAQ\n</summary><transcript>\nMaya Chen: I'll share the usability test results by Thursday.\nSam Rivera: I'm already updating the signup form copy.\n</transcript></meeting-notes>",
      [person("maya", "Maya Chen"), person("sam", "Sam Rivera")],
      "notion-user",
    );
    expect(notionItem).toMatchObject({ kind: "meeting", writtenByMe: null });
    expect(notionItem.text).not.toContain("Alex Kim");

    const quotes = ["Share usability test results by Thursday", "Update signup form copy", "Prepare launch FAQ"];
    const notionComplete = (async () => ({
      model: "test/llm",
      data: { candidates: quotes.map((quote) => ({ ...raw(quote), owner: "me", owner_confidence: 0.99 })) },
    })) as CompleteJson;
    const requests: { state: unknown; questions: Record<string, unknown> }[] = [];
    const notionDecide: Decide = async (request) => {
      requests.push(request);
      const quote = (request.state as { candidate: { quote: string } }).candidate.quote;
      const owner = quote === "Prepare launch FAQ" ? "unassigned" : "someone_else";
      return {
        model: "test/jev",
        answers: {
          ...answers(0.95),
          meeting_owner: { type: "choice", choice: owner, probabilities: { [owner]: 0.95 } },
        },
      };
    };

    const result = await runPipeline({ ...notionItem, identity: { name: "Alex Kim", aliases: ["Alex"], emails: ["alex@example.test"] } }, {
      complete: notionComplete,
      decide: notionDecide,
    });

    expect(result.judged.map(({ judge }) => judge.decision)).toEqual(["reject", "reject", "reject"]);
    expect(result.summary).toMatchObject({ auto: 0, confirm: 0, reject: 3 });
    expect(result.summary.promptVersions.judge).toBe(MEETING_JUDGE_PROMPT_VERSION);
    expect(requests).toHaveLength(3);
    for (const request of requests) {
      expect(request.questions).toHaveProperty("meeting_owner");
      expect(request.state).toMatchObject({ user: { position: "unknown" }, source: { kind: "meeting" } });
    }
  });

  it("후보가 없어도 회의에 선택될 판정 프롬프트 버전을 기록한다", async () => {
    const noCandidates = (async () => ({ model: "test/llm", data: { candidates: [] } })) as CompleteJson;
    const result = await runPipeline(input, { complete: noCandidates, decide });
    expect(result.judged).toEqual([]);
    expect(result.summary.promptVersions.judge).toBe(MEETING_JUDGE_PROMPT_VERSION);
  });

  it("후보가 없어도 연결자가 분류한 일반 문서에 선택될 판정 프롬프트 버전을 기록한다", async () => {
    const noCandidates = (async () => ({ model: "test/llm", data: { candidates: [] } })) as CompleteJson;
    const result = await runPipeline({ ...input, kind: "doc", writtenByMe: false }, { complete: noCandidates, decide });
    expect(result.judged).toEqual([]);
    expect(result.summary.promptVersions.judge).toBe(DOCUMENT_JUDGE_PROMPT_VERSION);
  });

  it("중립 제목의 일반 Notion 문서도 전체 문맥으로 다른 화자·무담당 액션을 걸러낸다", async () => {
    const person = (id: string, name: string) => ({ object: "user" as const, id, name, type: "person", person: {} });
    const page: NotionPage = {
      object: "page",
      id: "notion-neutral-retrospective",
      url: "https://www.notion.so/notion-neutral-retrospective",
      created_time: "2026-10-06T05:00:00.000Z",
      last_edited_time: "2026-10-06T05:10:00.000Z",
      created_by: { id: "notion-user" },
      parent: { type: "data_source_id" },
      properties: {
        Name: { type: "title", title: [{ plain_text: "Q3 Launch Retrospective" }] },
        Attendees: { type: "people", people: [person("maya", "Maya Chen"), person("sam", "Sam Rivera")] },
      },
    };
    const quotes = [
      "Maya Chen — Share usability test results by Thursday",
      "Sam Rivera — Update signup form copy",
      "Prepare launch FAQ",
    ];
    const filler = Array.from({ length: 160 }, (_, i) => `Project note ${i + 1}: status and decisions from this sprint.`).join("\n");
    const notionItem = pageToItem(page, [
      "## Retrospective notes",
      "Maya Chen: I will share the usability test results by Thursday.",
      "Sam Rivera: I am updating the signup form copy.",
      filler,
      "## Action items",
      `- [ ] ${quotes[0]}`,
      `- [ ] ${quotes[1]}`,
      `- [ ] ${quotes[2]}`,
    ].join("\n"), [person("maya", "Maya Chen"), person("sam", "Sam Rivera")], "notion-user");
    expect(notionItem).toMatchObject({ kind: "doc", writtenByMe: true, title: "Q3 Launch Retrospective" });
    expect(notionItem.text).not.toContain("<meeting-notes>");

    const notionComplete = (async () => ({
      model: "test/llm",
      data: { candidates: quotes.map((quote) => ({ ...raw(quote), owner: "me", owner_confidence: 0.99 })) },
    })) as CompleteJson;
    const requests: { state: unknown; questions: Record<string, unknown> }[] = [];
    const notionDecide: Decide = async (request) => {
      requests.push(request);
      const quote = (request.state as { candidate: { quote: string } }).candidate.quote;
      const owner = quote.startsWith("Prepare") ? "unassigned" : "someone_else";
      return {
        model: "test/jev",
        answers: {
          ...answers(0.95),
          document_owner: { type: "choice", choice: owner, probabilities: { [owner]: 0.95 } },
        },
      };
    };

    const result = await runPipeline({ ...notionItem, identity: { name: "Alex Kim", aliases: ["Alex"], emails: ["alex@example.test"] } }, {
      complete: notionComplete,
      decide: notionDecide,
    });

    expect(result.judged.map(({ judge }) => judge.decision)).toEqual(["reject", "reject", "reject"]);
    expect(result.summary).toMatchObject({ auto: 0, confirm: 0, reject: 3, promptVersions: { judge: WRITTEN_BY_ME_DOCUMENT_PROMPT_VERSION } });
    expect(requests).toHaveLength(3);
    for (const request of requests) {
      expect(request.questions).toHaveProperty("document_owner");
      expect(request.state).toMatchObject({ user: { position: "unknown" }, source: { kind: "doc", written_by_me: true } });
      const context = (request.state as { document_context: string }).document_context;
      expect(context.length).toBeLessThanOrEqual(5000);
      expect(context).toContain("Maya Chen:");
      expect(context).toContain("Sam Rivera:");
      expect(context).toContain("Prepare launch FAQ");
    }
  });

  it("중립 제목 문서에서 사용자가 관련 인물로 연결됐어도 무담당 액션은 unknown 확인으로 남긴다", async () => {
    const person = (id: string, name: string) => ({ object: "user" as const, id, name, type: "person", person: {} });
    const page: NotionPage = {
      object: "page",
      id: "notion-neutral-dpa",
      url: "https://www.notion.so/notion-neutral-dpa",
      created_time: "2026-10-06T05:00:00.000Z",
      last_edited_time: "2026-10-06T05:10:00.000Z",
      created_by: { id: "notion-user" },
      parent: { type: "data_source_id" },
      properties: {
        Name: { type: "title", title: [{ plain_text: "Contract renewal summary" }] },
        Attendees: { type: "people", people: [person("alex", "Alex Kim"), person("casey", "Casey Nolan")] },
      },
    };
    const notionItem = pageToItem(page, "## Action items\n- [ ] Send updated DPA draft by Monday", [person("alex", "Alex Kim"), person("casey", "Casey Nolan")], "notion-user");
    expect(notionItem).toMatchObject({ kind: "doc", writtenByMe: true });

    const notionComplete = (async () => ({
      model: "test/llm",
      data: { candidates: [{ ...raw("Send updated DPA draft by Monday"), owner: "me", owner_confidence: 0.99 }] },
    })) as CompleteJson;
    const notionDecide: Decide = async () => ({
      model: "test/jev",
      answers: {
        ...answers(0.95),
        document_owner: { type: "choice", choice: "unassigned", probabilities: { unassigned: 0.95 } },
      },
    });
    const identity = { name: "Alex Kim", aliases: ["Alex"], emails: ["alex@example.test"] };
    const result = await runPipeline({ ...notionItem, identity }, { complete: notionComplete, decide: notionDecide });

    expect(result.judged[0].judge).toMatchObject({ decision: "confirm", ownerAmbiguous: true, reasons: ["NOT_MY_ACTION"] });
    const store = new InMemoryActionStore();
    const embed = async (texts: string[]) => texts.map(() => Object.assign(new Array(EMBEDDING_DIMENSIONS).fill(0), { 0: 1 }));
    await mergeJudged(store, result.judged, {
      id: notionItem.externalId,
      kind: notionItem.kind,
      text: notionItem.text,
      occurredAt: notionItem.occurredAt,
    }, identity, { embed, decide: notionDecide, newId: () => "doc-attendee-action" });
    expect(resolveAction(store.all()[0].claims).owner.value).toBe("unknown");
    expect(projectAction(store.all()[0].title, store.all()[0].claims, store.all()[0].confirmReasons)).toMatchObject({
      owner: "unknown",
      needs_confirmation: true,
    });
  });

  it("작성자가 사용자이고 개인 체크리스트인 일반 Notion 문서는 정상적으로 유지한다", async () => {
    const page: NotionPage = {
      object: "page",
      id: "notion-personal-checklist",
      url: "https://www.notion.so/notion-personal-checklist",
      created_time: "2026-10-06T05:00:00.000Z",
      last_edited_time: "2026-10-06T05:10:00.000Z",
      created_by: { id: "notion-user" },
      parent: { type: "data_source_id" },
      properties: { Name: { type: "title", title: [{ plain_text: "My launch checklist" }] } },
    };
    const notionItem = pageToItem(page, "## My personal checklist\n- [ ] Replace portfolio domain DNS", [], "notion-user");
    expect(notionItem).toMatchObject({ kind: "doc", writtenByMe: true });
    const notionComplete = (async () => ({
      model: "test/llm",
      data: { candidates: [{ ...raw("Replace portfolio domain DNS"), owner: "me", owner_confidence: 0.99 }] },
    })) as CompleteJson;
    const result = await runPipeline({ ...notionItem, identity: { name: "Alex Kim", aliases: ["Alex"], emails: [] } }, {
      complete: notionComplete,
      decide,
    });

    expect(result.judged[0].judge.decision).toBe("auto");
    expect(result.summary.promptVersions.judge).toBe(WRITTEN_BY_ME_DOCUMENT_PROMPT_VERSION);
  });
});

describe("runPipeline의 작성자", () => {
  it("사용자가 쓴 원문이면 판정 state에 written_by_me를 넘긴다", async () => {
    const states: unknown[] = [];
    const recording: Decide = async (request) => {
      states.push(request.state);
      return decide(request);
    };
    await runPipeline({ ...input, kind: "doc", writtenByMe: true }, { complete, decide: recording });
    expect(states).toHaveLength(2);
    expect(states.every((s) => (s as { source: { written_by_me?: boolean } }).source.written_by_me === true)).toBe(true);
  });
});

describe("runPipeline의 메일 인용", () => {
  const mail = {
    ...input,
    kind: "email" as const,
    fromConnector: true,
    text: "제목: Re: 견적서\n\n네, 금요일까지 제안서 보내드릴게요.\n\n2026년 10월 14일 (수) 오후 2:05, 김대표 <k@x.example>님이 작성:\n\n> 견적서는 박팀장이 드릴게요.",
    participants: { from: { name: "나" }, to: [{ name: "김대표" }] },
  };

  it("메일이면 인용된 옛 메일에만 있는 후보는 Jev에 묻기 전에 버린다", async () => {
    let asked = 0;
    const counting: Decide = async (request) => {
      asked++;
      return decide(request);
    };
    const result = await runPipeline(mail, { complete, decide: counting });
    expect(result.judged.map((j) => j.candidate.quote)).toEqual(["금요일까지 제안서 보내드릴게요"]);
    // 원문에 없는 인용 하나 + 인용된 옛 메일에만 있는 후보 하나
    expect(result.droppedCount).toBe(2);
    // 이유별 개수와 기록용 후보 (인용이 원문에 없는 후보는 기록에 남기지 않는다)
    expect(result.summary.droppedByReason).toEqual({ quoteNotFound: 1, quotedHistory: 1 });
    expect(result.droppedQuotedHistory.map((c) => c.quote)).toEqual(["견적서는 박팀장이 드릴게요"]);
    expect(asked).toBe(1);
  });

  it("직접 붙여 넣은 메일이면 인용 속 후보도 그대로 Jev에 묻는다", async () => {
    const result = await runPipeline({ ...mail, fromConnector: false }, { complete, decide });
    expect(result.judged.map((j) => j.candidate.quote)).toEqual(["금요일까지 제안서 보내드릴게요", "견적서는 박팀장이 드릴게요"]);
    expect(result.droppedCount).toBe(1);
    expect(result.droppedQuotedHistory).toEqual([]);
    expect(result.summary.droppedByReason).toEqual({ quoteNotFound: 1, quotedHistory: 0 });
  });

  it("같은 원문이라도 메일이 아니면 이 규칙을 쓰지 않는다", async () => {
    const result = await runPipeline({ ...mail, kind: "note" }, { complete, decide });
    expect(result.judged.map((j) => j.candidate.quote)).toEqual(["금요일까지 제안서 보내드릴게요", "견적서는 박팀장이 드릴게요"]);
    expect(result.droppedCount).toBe(1);
  });
});
