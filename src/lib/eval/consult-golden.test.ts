import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it, vi } from "vitest";

import type { JevDecision } from "@/lib/ai/jev";

import { proposalIntact } from "@/lib/conversation/proposal";
import { respondToMessage, type TurnPlan } from "@/lib/conversation/respond";

import { consultCaseSchema, consultInputOf, findConsultLabelErrors, formatOrganizeMetrics, observeOrganize, organizeMetrics, scoreConsultCase, type ConsultCase } from "./consult-golden";

// 대화 상담 골든셋(evals/consult)의 형식 · 라벨 · 입력 만들기 · 채점. 실제 모델 채점은 npm run eval -- --consult (이번 PR에서는 실행하지 않음).

const DIR = path.resolve(__dirname, "../../../evals/consult");
const cases: ConsultCase[] = readdirSync(DIR)
  .filter((f) => f.endsWith(".json"))
  .sort()
  .map((f) => consultCaseSchema.parse(JSON.parse(readFileSync(path.join(DIR, f), "utf8"))));

const emptyPlan = (overrides: Partial<TurnPlan> = {}): TurnPlan =>
  ({
    intent: { kind: "consult", confidence: 0.9, judge_version: "intent-v1" },
    route: "consult",
    user: { refs: {} },
    reply: { text: "등록된 열린 할 일은 없어요. 오늘 하려는 일이 있나요?", segments: [{ text: "x", tier: "T5" }], citations: [], refs: {}, content: { segments: [], citations: [], proposal: null, asks: null, used: null, window: null } },
    memory: [],
    adopt: null,
    summary: {},
    ...overrides,
  }) as TurnPlan;

describe("evals/consult", () => {
  it("기존 15건 + 이슈 정리 24건(org 19 · neg 5) · 파일 이름 = id · 라벨 오류 없음 · 기준 A01–A05 · A34 · A41 · ARCH01 · 02 · 04, AC-27 · 29 · 30을 모두 덮는다", () => {
    const legacy = cases.filter((c) => !/^(org|neg)-/.test(c.id));
    expect(legacy).toHaveLength(15);
    expect(cases.filter((c) => c.id.startsWith("org-"))).toHaveLength(19);
    expect(cases.filter((c) => c.id.startsWith("neg-"))).toHaveLength(5);
    for (const golden of cases) expect(findConsultLabelErrors(golden), golden.id).toEqual([]);
    for (const file of readdirSync(DIR).filter((f) => f.endsWith(".json"))) expect(consultCaseSchema.parse(JSON.parse(readFileSync(path.join(DIR, file), "utf8"))).id).toBe(file.replace(/\.json$/, ""));
    const maps = new Set(cases.flatMap((c) => c.maps_to));
    for (const id of ["A01", "A02", "A04", "A05", "A34", "A41", "ARCH01", "ARCH02", "ARCH04", "AC-27", "AC-29", "AC-30"]) expect(maps.has(id), id).toBe(true);
  });

  it("라벨 검사: 원문에 없는 근거 구절 · 없는 정정 대상 · 깨진 정규식 · 열린 제안 없는 채택 기대를 잡는다", () => {
    const base = cases.find((c) => c.id === "a05-injection-send-mail")!;
    const broken: ConsultCase = {
      ...base,
      records: { ...base.records, open_actions: [{ ...base.records.open_actions[0], quotes: [{ source: "s1", quote: "원문에 없는 구절" }] }] },
      expect: { ...base.expect, corrects: ["m9"], reply_must_not_match: ["("], adopt: true },
    };
    const errors = findConsultLabelErrors(broken);
    expect(errors.some((e) => e.includes("인용이 원문 s1에 없습니다"))).toBe(true);
    expect(errors.some((e) => e.includes("없는 memory m9"))).toBe(true);
    expect(errors.some((e) => e.includes("깨진 정규식"))).toBe(true);
    expect(errors.some((e) => e.includes("열린 제안"))).toBe(true);
  });

  it("입력 만들기: 지금 메시지가 창의 마지막, 앞 제안은 hash가 맞고, 앱이 고른 대상 · 범위 기억이 이어진다", () => {
    const adopt = cases.find((c) => c.id === "a41-adopt-open-proposal")!;
    const { input } = consultInputOf(adopt);
    expect(input.window.at(-1)).toMatchObject({ id: input.message.id, role: "user", text: "그렇게 해" });
    const proposal = input.window.at(-2)!;
    expect(proposalIntact(proposal.refs.proposal!, proposal.content!.proposal)).toBe(true);
    const mixed = consultInputOf(cases.find((c) => c.id === "a34-mixed-read-and-delegate")!);
    expect(mixed.input.selected).toEqual([{ kind: "action", id: mixed.ids("a1"), title: "견적서 보내기" }]);
    const partial = consultInputOf(cases.find((c) => c.id === "a04-partial-shown")!);
    expect([partial.context.openTotal, partial.context.openActions.length]).toEqual([30, 8]);
  });

  it("채점: 금지 표현(등록 0건을 할 일 없음으로 단정)은 미달, 범위를 밝힌 답은 통과", () => {
    const a01 = cases.find((c) => c.id === "a01-no-open-one-done")!;
    const { ids } = consultInputOf(a01);
    expect(scoreConsultCase(a01, emptyPlan(), ids).pass).toBe(true);
    const bad = scoreConsultCase(a01, emptyPlan({ reply: { ...emptyPlan().reply, text: "오늘은 할 일이 없어요." } }), ids);
    expect(bad.pass).toBe(false);
    expect(bad.checks.must_not_match).toBe(false);
    const redo = scoreConsultCase(a01, emptyPlan({ reply: { ...emptyPlan().reply, content: { ...emptyPlan().reply.content, proposal: { kind: "create_action", title: "주간 보고서 다시 보내기" } } } }), ids);
    expect(redo.checks.proposal_titles).toBe(false);
  });
});

describe("evals/consult: 이슈 정리 (D4c-2)", () => {
  const organizeCases = cases.filter((c) => c.id.startsWith("org-"));

  it("라벨 검사: 없는 프로젝트 · 이슈, 병합은 둘 + into, outcome write는 이동 · 빼기만, 기억 쓰기 기대와 정리를 함께 두지 않는다", () => {
    const base = cases.find((c) => c.id === "org-merge-into-ko")!;
    const errors = (patch: Partial<ConsultCase["expect"]>, over: Partial<ConsultCase> = {}) => findConsultLabelErrors({ ...base, ...over, expect: { ...base.expect, ...patch } });
    expect(errors({ organize: { op: "merge", targets: ["i144"], into: "i144", outcome: "card" } }).some((e) => e.includes("병합은 targets 둘"))).toBe(true);
    expect(errors({ organize: { op: "merge", targets: ["i144", "i139"], into: "i999", outcome: "card" } }).some((e) => e.includes("없는 이슈 i999"))).toBe(true);
    expect(errors({ organize: { op: "delete", targets: ["i141"], outcome: "write" } }).some((e) => e.includes("write는 이동 · 빼기만"))).toBe(true);
    expect(errors({ organize: { op: "move", targets: ["i139"], project: "p_nope", outcome: "write" } }).some((e) => e.includes("없는 project p_nope"))).toBe(true);
    expect(errors({ organize: { op: "none", targets: [], outcome: "write" } }).some((e) => e.includes("op none에는 outcome이 없습니다"))).toBe(true);
    expect(errors({ organize: { op: "move", targets: ["i139"] } }).some((e) => e.includes("outcome이 필요"))).toBe(true);
    expect(errors({ organize: { op: "delete", targets: ["i141"], outcome: "card" }, memory_writes: { min: 1, max: 1 }, memory_statements_contain: ["x"] }).some((e) => e.includes("기억 쓰기 기대를 함께"))).toBe(true);
    const dup = errors({}, { projects: [...base.projects, base.projects[0]] });
    expect(dup.some((e) => e.includes("project id가 중복"))).toBe(true);
    const sameNumber = errors({}, { records: { ...base.records, open_actions: base.records.open_actions.map((a) => ({ ...a, number: 7 })) } });
    expect(sameNumber.some((e) => e.includes("이슈 번호가 중복"))).toBe(true);
    const badHistory = errors({}, { history: [{ role: "assistant", text: "x", action_refs: [], proposal: { kind: "merge", targets: ["i144"], state: "open" } }] });
    expect(badHistory.some((e) => e.includes("병합은 대상 둘"))).toBe(true);
  });

  it("입력 만들기: 이슈 번호 · 상태 · 멤버십 · 보관 여부가 organize_lookup 모양으로, 앞 카드는 hash가 맞고, 칩(selected_contexts)이 이어진다", () => {
    const chip = consultInputOf(cases.find((c) => c.id === "org-move-chip")!);
    expect(chip.input.selectedContexts).toEqual([chip.ids("p_launch")]);
    expect(chip.lookup.actions.find((a) => a.number === 139)).toMatchObject({ id: chip.ids("i139"), status: "open", version: 2, open_sessions: 1, evidence_count: 2, contexts: [{ id: chip.ids("p_tf"), name: "Taskforce", status: "active" }] });
    const archived = consultInputOf(cases.find((c) => c.id === "org-move-archived")!);
    expect(archived.lookup.contexts.find((c) => c.name === "Old")).toMatchObject({ status: "archived", kind: "project" });
    const dropped = consultInputOf(cases.find((c) => c.id === "org-delete-dropped")!);
    expect(dropped.lookup.actions.find((a) => a.number === 150)!.status).toBe("dropped");
    expect(dropped.context.openActions.map((a) => a.title)).not.toContain("지운 일");
    for (const id of ["org-delete-confirm-typed", "org-merge-confirm-typed"]) {
      const { input } = consultInputOf(cases.find((c) => c.id === id)!);
      const card = input.window.at(-2)!;
      expect(proposalIntact(card.refs.proposal!, card.content!.proposal)).toBe(true);
      expect(card.content!.asks).toBe("confirm");
    }
    const pending = consultInputOf(cases.find((c) => c.id === "org-move-pending-answer")!).input.window.at(-2)!;
    expect(pending.content).toMatchObject({ asks: "organize", organize: { state: "pending", op: "move", missing: "project" } });
  });

  it("채점: 정리 기대(outcome · op · 대상 · 프로젝트 · 남는 쪽)를 보고, 쓰기를 기대하지 않았는데 쓰면 no_false_write가 실패한다", () => {
    const golden = cases.find((c) => c.id === "org-move-number-ko")!;
    const { ids } = consultInputOf(golden);
    const move = [{ action_id: ids("i139"), add: { context_id: ids("p_launch"), expected_version: 1 }, remove: { context_id: ids("p_tf"), expected_version: 1 } }];
    const plan = emptyPlan({ intent: { kind: "organize", confidence: 0.95, judge_version: "intent-v2" }, route: "organize", move, reply: { ...emptyPlan().reply, text: "옮겼어요: #139 → Launch" } });
    const ok = scoreConsultCase(golden, plan, ids);
    expect(ok.checks).toMatchObject({ organize_outcome: true, organize_op: true, organize_targets: true, organize_project: true, no_false_write: true });
    expect(ok.pass).toBe(true);
    // 다른 이슈 · 다른 프로젝트
    const wrongTarget = scoreConsultCase(golden, emptyPlan({ ...plan, move: [{ ...move[0], action_id: ids("i140") }] }), ids);
    expect(wrongTarget.checks.organize_targets).toBe(false);
    const wrongProject = scoreConsultCase(golden, emptyPlan({ ...plan, move: [{ ...move[0], add: { context_id: ids("p_tf"), expected_version: 1 } }] }), ids);
    expect(wrongProject.checks.organize_project).toBe(false);
    // 쓰지 않고 물었다면 outcome 미달
    expect(scoreConsultCase(golden, emptyPlan({ ...plan, move: null }), ids).checks.organize_outcome).toBe(false);

    // 거짓 쓰기: 카드를 기대한 케이스(삭제)에서 move를 썼다 / 채택을 기대하지 않았는데 채택했다
    const del = cases.find((c) => c.id === "org-delete-one-ko")!;
    const falseWrite = scoreConsultCase(del, emptyPlan({ route: "organize", move }), consultInputOf(del).ids);
    expect(falseWrite.checks.no_false_write).toBe(false);
    expect(falseWrite.pass).toBe(false);
    const adopted = scoreConsultCase(del, emptyPlan({ route: "organize", adopt: { kind: "move", proposal_message_id: "m", proposal_id: "p", payload_hash: "h", moves: move } }), consultInputOf(del).ids);
    expect(adopted.checks.no_false_write).toBe(false);
    // 기존 상담 케이스에도 적용: 쓰기 0이면 통과, move가 나오면 실패
    const legacy = cases.find((c) => c.id === "a01-no-open-one-done")!;
    expect(scoreConsultCase(legacy, emptyPlan(), consultInputOf(legacy).ids).checks.no_false_write).toBe(true);
    expect(scoreConsultCase(legacy, emptyPlan({ move }), consultInputOf(legacy).ids).checks.no_false_write).toBe(false);
  });

  it("정리가 아니어야 하는 케이스(neg-*): route가 organize면 미달, 아니면 통과", () => {
    const neg = cases.find((c) => c.id === "neg-lookup-number")!;
    const { ids } = consultInputOf(neg);
    expect(scoreConsultCase(neg, emptyPlan({ intent: { kind: "lookup", confidence: 0.9, judge_version: "v" } }), ids).checks.organize_outcome).toBe(true);
    const wrong = scoreConsultCase(neg, emptyPlan({ route: "organize", intent: { kind: "organize", confidence: 0.9, judge_version: "v" }, reply: { ...emptyPlan().reply, content: { ...emptyPlan().reply.content, asks: "clarify" } } }), ids);
    expect(wrong.checks.organize_outcome).toBe(false);
    expect(wrong.pass).toBe(false);
    expect(observeOrganize(emptyPlan()).outcome).toBeNull();
  });

  it("organize 케이스는 기대한 판정(Jev)을 가짜로 주면 코드 규칙만으로 모두 통과한다 — 대상 · 프로젝트 · 남는 쪽 · 카드가 케이스 데이터와 어긋나지 않는다 (모델 판정은 npm run eval -- --consult)", async () => {
    let n = 0;
    for (const golden of organizeCases.filter((c) => !c.expect.adopt)) {
      const { input, ids, lookup } = consultInputOf(golden);
      const expected = golden.expect.organize;
      const decide = vi.fn(async (request: { questions: Record<string, { criteria?: Record<string, string> }> }): Promise<JevDecision> => {
        const keys = Object.keys(request.questions);
        if (keys.includes("op") || keys.includes("into")) {
          const answers: JevDecision["answers"] = {};
          if (keys.includes("op")) answers.op = { type: "choice", choice: expected?.op ?? "other", confidence: 0.95, probabilities: { [expected?.op ?? "other"]: 0.95 } };
          if (keys.includes("into")) {
            // 병합이 아닌 케이스도 이슈가 둘이면 같이 묻는다: 기대한 남는 쪽이 있으면 그것(확신 높음), 없으면 확신 낮은 아무 쪽
            const wanted = expected?.into ? lookup.actions.find((a) => a.id === ids(expected.into!))! : null;
            const choice = wanted ? `#${wanted.number}` : Object.keys(request.questions.into.criteria!)[0];
            const confidence = wanted ? 0.9 : 0.2;
            answers.into = { type: "choice", choice, confidence, probabilities: { [choice]: confidence } };
          }
          return { model: "fake", answers };
        }
        const kind = golden.expect.intent_any[0];
        return { model: "fake", answers: { intent: { type: "choice", choice: kind, confidence: 0.95, probabilities: { [kind]: 0.95 } }, remember: { type: "noul", noul: 0 }, read: { type: "noul", noul: 0 } } };
      });
      const plan = await respondToMessage(input, {
        decide: decide as never,
        complete: vi.fn(async () => {
          throw new Error("상담 LLM은 정리 분기에서 부르지 않는다");
        }) as never,
        retrieve: async () => {
          throw new Error("정리 분기는 기록 읽기를 하지 않는다");
        },
        organizeLookup: async () => lookup,
        newId: () => `eeeeeeee-0000-4000-8000-${String(++n).padStart(12, "0")}`,
      });
      const score = scoreConsultCase(golden, plan, ids);
      expect(score.pass, `${golden.id}: ${JSON.stringify(Object.entries(score.checks).filter(([, ok]) => ok === false))}`).toBe(true);
    }
  });
});

describe("organizeMetrics: 계약 5.3 요약 한 줄", () => {
  const byId = (id: string) => cases.find((c) => c.id === id)!;
  const run = (id: string, plan: TurnPlan) => {
    const golden = byId(id);
    return { golden, plan, score: scoreConsultCase(golden, plan, consultInputOf(golden).ids) };
  };

  it("양성 중 intent 재현율 · 정밀도, op · 대상 · 남는 쪽 정확도, 거짓 쓰기, 기준선 대비 회귀를 센다", () => {
    const move = (id: string, number: string, project: string) => {
      const { ids } = consultInputOf(byId(id));
      return emptyPlan({
        route: "organize",
        intent: { kind: "organize", confidence: 0.9, judge_version: "v" },
        move: [{ action_id: ids(number), add: { context_id: ids(project), expected_version: 1 }, remove: null }],
      });
    };
    const good = run("org-move-chip", move("org-move-chip", "i140", "p_launch"));
    const wrongTarget = run("org-move-number-ko", move("org-move-number-ko", "i140", "p_launch")); // 대상이 틀림 (op는 맞다)
    const missed = run("org-remove", emptyPlan()); // 정리를 놓침 → 재현율 분모
    const falsePositive = run("neg-lookup-number", emptyPlan({ route: "organize", intent: { kind: "organize", confidence: 0.9, judge_version: "v" } })); // 정리가 아닌데 organize
    const falseWrite = run("org-delete-one-ko", emptyPlan({ route: "organize", move: good.plan.move }));
    const legacyOk = run("a01-no-open-one-done", emptyPlan());

    const m = organizeMetrics([good, wrongTarget, missed, falsePositive, falseWrite, legacyOk], new Set(["a01-no-open-one-done", "org-move-chip", "neg-lookup-number"]));
    expect(m.intent).toEqual({ truePositive: 3, falsePositive: 1, falseNegative: 1 });
    expect(m.op).toEqual({ ok: 2, n: 4 }); // 놓친 케이스(정리를 안 함)와 삭제를 이동으로 쓴 케이스는 틀린 것으로 센다
    expect(m.targets).toEqual({ ok: 1, n: 4 });
    expect(m.falseWrites).toBe(1);
    // 기준선에서 통과: legacy(지금도 통과) · org-move-chip(지금 통과) · neg-lookup-number(지금 실패 → 회귀 1)
    expect(m.regressions).toBe(1);
    expect(formatOrganizeMetrics(m)).toBe(
      "organize: intent 정밀도 3/4 · 재현율 3/4 · op 정확도 2/4 · 대상 정확도 1/4 · 남는 쪽 정확도 0/0 · 거짓 쓰기 1 · 기존 상담 회귀 1",
    );
    expect(organizeMetrics([good], null).regressions).toBeNull();
    expect(formatOrganizeMetrics(organizeMetrics([good], null))).toContain("(기준선 없음)");
  });
});
