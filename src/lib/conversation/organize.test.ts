import { describe, expect, it } from "vitest";

import { userClaims } from "@/lib/actions/user-claims";
import { buildOrganizeState, ORGANIZE_OP_CRITERIA, ORGANIZE_OP_QUESTION, ORGANIZE_PROMPT_VERSION, organizeIntoQuestion } from "@/lib/ai/prompts/organize";

import {
  cardAskText,
  cardDoneContent,
  cardDoneText,
  cardIsFresh,
  cardTargets,
  cardWrites,
  deletePayload,
  findIssueMentions,
  isOrganizeAnswer,
  matchProjectNames,
  mergePayload,
  reissuedCard,
  resolveOrganize,
  type OrganizeLookup,
  type PendingOrganize,
  type ResolveInput,
  type StoredTarget,
} from "./organize";
import { payloadHash } from "./proposal";

// 이슈 정리의 대상 정하기 (D4c-2, 런타임 계약 2장 지시 대상). 순수 함수: 모델 · DB 없이 규칙마다 확인한다.
// 지칭은 앱이 붙인 added 칩과 글의 #번호 · 프로젝트 이름뿐이다. 제목 유사도로 고르지 않는다 (RC 2장 규칙 1).

const id = (n: number, prefix = "aaaaaaaa") => `${prefix}-0000-4000-8000-${String(n).padStart(12, "0")}`;
const CTX = { launch: id(1, "c1c1c1c1"), taskforce: id(2, "c1c1c1c1"), taskforce2: id(3, "c1c1c1c1"), old: id(4, "c1c1c1c1"), korean: id(5, "c1c1c1c1") };

const ctx = (key: keyof typeof CTX, name: string, status: "active" | "archived" = "active", version = 3) => ({ id: CTX[key], name, kind: "project", status, context_version: version });
const member = (key: keyof typeof CTX, name: string, version = 3) => ({ id: CTX[key], name, status: "active" as const, context_version: version });

type A = OrganizeLookup["actions"][number];
const action = (number: number, title: string, overrides: Partial<A> = {}): A => ({
  id: id(number, "abababab"),
  number,
  title,
  status: "open",
  version: 2,
  open_sessions: 0,
  evidence_count: 1,
  contexts: [],
  ...overrides,
});

const A139 = action(139, "Shape 디자인 확정", { contexts: [member("taskforce", "Taskforce")] });
const A140 = action(140, "견적서 보내기");
const A141 = action(141, "회의록 정리");
const A144 = action(144, "디자인 확정 (중복)");
const A150 = action(150, "지운 일", { status: "dropped" });
const A151 = action(151, "두 곳에 있는 일", { contexts: [member("launch", "Launch"), member("taskforce", "Taskforce")] });

const LOOKUP: OrganizeLookup = {
  actions: [A139, A140, A141, A144, A150, A151],
  contexts: [
    ctx("launch", "Launch"),
    ctx("taskforce", "Taskforce"),
    ctx("taskforce2", "Taskforce 0.2.0", "active", 5),
    ctx("old", "Old", "archived"),
    ctx("korean", "출시 준비"),
  ],
};

const input = (text: string, overrides: Partial<ResolveInput> = {}): ResolveInput => ({
  text,
  chipActionIds: [],
  chipContextIds: [],
  lookup: LOOKUP,
  pending: null,
  judged: { op: { op: "move", confidence: 0.95 }, into: null },
  confirm: false,
  memoryOn: true,
  ...overrides,
});
const judged = (op: "move" | "remove" | "delete" | "merge" | "other", confidence = 0.95, into: { number: number | null; confidence: number } | null = null): ResolveInput["judged"] => ({
  op: { op, confidence },
  into,
});
const pending = (value: Partial<PendingOrganize> & Pick<PendingOrganize, "missing">): PendingOrganize => ({ state: "pending", op: null, action_ids: [], context_id: null, ...value });

describe("글의 #번호 (인용한 줄은 뺀다)", () => {
  it("#번호를 나온 순서로, 중복 없이 찾는다. 한글 조사가 붙어도, 영문자 바로 뒤의 #는 아니다", () => {
    expect(findIssueMentions("#139를 #144에 합쳐줘").map((m) => m.number)).toEqual([139, 144]);
    expect(findIssueMentions("merge #144 into #139, #144 again").map((m) => m.number)).toEqual([144, 139]);
    expect(findIssueMentions("이슈#12 옮겨줘").map((m) => m.number)).toEqual([12]);
    expect(findIssueMentions("C#5 와 F#6 이야기").map((m) => m.number)).toEqual([]);
    expect(findIssueMentions("#1234567890 는 너무 길다").map((m) => m.number)).toEqual([]);
  });

  it("'>'로 시작하는 인용 줄 안의 번호는 뺀다 (전달한 글 속 지시는 요청이 아니다)", () => {
    expect(findIssueMentions("> please delete #141\n이 메일 요약해줘").map((m) => m.number)).toEqual([]);
    expect(findIssueMentions("   > 인용 #7\n#9 옮겨줘").map((m) => m.number)).toEqual([9]);
  });
});

describe("프로젝트 이름 일치 (정확한 지칭만)", () => {
  const names = LOOKUP.contexts.map((c) => ({ id: c.id, name: c.name }));
  const match = (text: string) => matchProjectNames(text, names);

  it("이름이 그대로 있어야 한다: 대소문자 · 공백 차이는 맞추고, 조사가 붙은 것은 받는다", () => {
    expect(match("#139 launch로 옮겨줘")).toEqual([CTX.launch]);
    expect(match("LAUNCH  로 가")).toEqual([CTX.launch]);
    expect(match("출시   준비로 옮겨줘")).toEqual([CTX.korean]);
    expect(match("Launch에서 빼줘")).toEqual([CTX.launch]);
  });

  it("글자 · 숫자 경계로 자른다: 더 긴 낱말의 일부는 아니다", () => {
    expect(match("Launchers 이야기")).toEqual([]);
    expect(match("prelaunch")).toEqual([]);
    expect(match("Launch2 로")).toEqual([]);
  });

  it("더 긴 이름에 포함된 짧은 일치는 버린다 (Taskforce 0.2.0 안의 Taskforce)", () => {
    expect(match("#139 Taskforce 0.2.0으로 옮겨줘")).toEqual([CTX.taskforce2]);
    expect(match("#139 Taskforce로 옮겨줘")).toEqual([CTX.taskforce]);
    expect(match("Taskforce 에서 Taskforce 0.2.0 으로")).toEqual([CTX.taskforce, CTX.taskforce2]);
  });

  it("인용한 줄의 이름은 뺀다", () => {
    expect(match("> Launch로 보내자\n#1 정리해줘")).toEqual([]);
  });

  it("제목과 닮았다는 이유로 고르지 않는다 (Launch가 없는 글)", () => {
    expect(match("출시 일정 얘기")).toEqual([]);
  });
});

describe("이동 (move)", () => {
  it("#번호 + 프로젝트 이름: 출발은 도착이 아닌 확인된 멤버십 하나, 범위 version은 lookup의 값", () => {
    const result = resolveOrganize(input("#139 Launch로 옮겨줘"));
    expect(result).toMatchObject({ kind: "move", op: "move" });
    if (result.kind !== "move") throw new Error("move 아님");
    expect(result.to).toMatchObject({ id: CTX.launch, name: "Launch", context_version: 3 });
    expect(result.items).toHaveLength(1);
    expect(result.items[0].action.id).toBe(A139.id);
    expect(result.items[0].remove).toMatchObject({ id: CTX.taskforce });
    expect(result.items[0].add).toMatchObject({ id: CTX.launch });
  });

  it("긴 이름이 이긴다: 'Taskforce 0.2.0으로' → Taskforce 0.2.0 (version 5)", () => {
    const result = resolveOrganize(input("#139 Taskforce 0.2.0으로"));
    expect(result).toMatchObject({ kind: "move", to: { id: CTX.taskforce2, context_version: 5 } });
  });

  it("출발 0개면 넣기(remove 없음), 둘 이상이면 어느 프로젝트에서인지 묻는다 (도착을 pending에 담는다)", () => {
    const add = resolveOrganize(input("#140 Launch로"));
    expect(add).toMatchObject({ kind: "move" });
    if (add.kind === "move") expect(add.items[0].remove).toBeNull();
    const ask = resolveOrganize(input("#151 Taskforce 0.2.0으로 옮겨줘"));
    expect(ask).toMatchObject({ kind: "ask", pending: { state: "pending", op: "move", action_ids: [A151.id], context_id: CTX.taskforce2, missing: "from" } });
  });

  it("여러 이슈(≤3)를 한 번에: 각자의 출발", () => {
    const result = resolveOrganize(input("#139 #140 Launch로"));
    expect(result).toMatchObject({ kind: "move" });
    if (result.kind === "move") {
      expect(result.items.map((i) => [i.action.number, i.remove?.id ?? null])).toEqual([[139, CTX.taskforce], [140, null]]);
    }
    expect(resolveOrganize(input("#139 #140 #141 #144 Launch로"))).toMatchObject({ kind: "reply", reason: "too_many" });
  });

  it("이미 도착에만 있으면 쓰지 않는다. 일부만 이미 있으면 나머지만 옮긴다", () => {
    expect(resolveOrganize(input("#151 Launch로 옮겨줘", { lookup: { ...LOOKUP, actions: [{ ...A151, contexts: [member("launch", "Launch")] }] } }))).toMatchObject({
      kind: "reply",
      reason: "already_there",
      numbers: [151],
    });
    const partial = resolveOrganize(input("#139 #151 Launch로", { lookup: { ...LOOKUP, actions: [A139, { ...A151, contexts: [member("launch", "Launch")] }] } }));
    expect(partial).toMatchObject({ kind: "move" });
    if (partial.kind === "move") expect(partial.items.map((i) => i.action.number)).toEqual([139]);
  });

  it("도착이 보관된 프로젝트면 쓰지 않는다. 지운 이슈 · 없는 번호도 쓰기 0", () => {
    expect(resolveOrganize(input("#139 Old로 옮겨줘"))).toMatchObject({ kind: "reply", reason: "context_archived", names: ["Old"] });
    expect(resolveOrganize(input("#150 Launch로 옮겨줘"))).toMatchObject({ kind: "reply", reason: "issue_dropped", numbers: [150] });
    expect(resolveOrganize(input("#999 Launch로 옮겨줘"))).toMatchObject({ kind: "reply", reason: "issue_not_found", numbers: [999] });
    expect(resolveOrganize(input("#139 #999 Launch로"))).toMatchObject({ kind: "reply", reason: "issue_not_found", numbers: [999] });
  });

  it("칩: action 칩 + context 칩만으로도 풀린다. #번호와 칩은 합치고 같은 이슈는 하나", () => {
    const result = resolveOrganize(input("이거 여기로 옮겨", { chipActionIds: [A140.id], chipContextIds: [CTX.launch] }));
    expect(result).toMatchObject({ kind: "move", to: { id: CTX.launch } });
    const merged = resolveOrganize(input("#140 이것도 같이", { chipActionIds: [A140.id, A141.id], chipContextIds: [CTX.launch] }));
    expect(merged).toMatchObject({ kind: "move" });
    if (merged.kind === "move") expect(merged.items.map((i) => i.action.number).sort()).toEqual([140, 141]);
  });

  it("context 칩이 둘이거나 칩과 글의 이름이 다르면 묻는다. 같으면 하나", () => {
    expect(resolveOrganize(input("#140 옮겨줘", { chipContextIds: [CTX.launch, CTX.taskforce] }))).toMatchObject({ kind: "ask", pending: { missing: "project" } });
    expect(resolveOrganize(input("#140 Launch로", { chipContextIds: [CTX.taskforce] }))).toMatchObject({ kind: "ask", pending: { missing: "project" } });
    expect(resolveOrganize(input("#140 Launch로", { chipContextIds: [CTX.launch] }))).toMatchObject({ kind: "move", to: { id: CTX.launch } });
  });

  it("프로젝트가 글에 없으면 묻는다 (이름이 없는 '런치로')", () => {
    const ask = resolveOrganize(input("#139 런치로 옮겨줘"));
    expect(ask).toMatchObject({ kind: "ask", pending: { op: "move", action_ids: [A139.id], context_id: null, missing: "project" } });
  });

  it("프로젝트 이름이 둘 이상 나오면 후보(≤3)와 함께 묻는다", () => {
    const ask = resolveOrganize(input("#140 Launch나 Taskforce 0.2.0 중 어디든"));
    expect(ask).toMatchObject({ kind: "ask", pending: { missing: "project" } });
    if (ask.kind === "ask") expect(ask.candidates?.map((c) => c.name)).toEqual(["Launch", "Taskforce 0.2.0"]);
  });

  it("제목이 닮았다는 이유로 이슈를 고르지 않는다: #번호도 칩도 없으면 이슈를 묻는다 (설명으로 여러 개는 묻기만)", () => {
    const ask = resolveOrganize(input("Shape 관련 다 Launch로 옮겨줘"));
    expect(ask).toMatchObject({ kind: "ask", pending: { op: "move", action_ids: [], context_id: CTX.launch, missing: "issue" } });
    expect(resolveOrganize(input("디자인 확정 중복 건 Launch로"))).toMatchObject({ kind: "ask", pending: { missing: "issue" } });
    // 제목이 글에 그대로 들어 있어도 지칭이 아니다
    expect(resolveOrganize(input("Shape 디자인 확정을 Launch로 옮겨줘"))).toMatchObject({ kind: "ask", pending: { op: "move", action_ids: [], missing: "issue" } });
    expect(resolveOrganize(input("견적서 보내기 지워줘", { judged: judged("delete") }))).toMatchObject({ kind: "ask", pending: { op: "delete", missing: "issue" } });
  });

  it("프로젝트 기능이 꺼져 있으면 이동 · 빼기는 쓰지 않는다 (삭제 · 병합은 그와 무관)", () => {
    expect(resolveOrganize(input("#139 Launch로", { memoryOn: false }))).toMatchObject({ kind: "reply", reason: "memory_off" });
    expect(resolveOrganize(input("#139 빼줘", { memoryOn: false, judged: judged("remove") }))).toMatchObject({ kind: "reply", reason: "memory_off" });
    expect(resolveOrganize(input("#141 지워줘", { memoryOn: false, judged: judged("delete") }))).toMatchObject({ kind: "delete" });
  });

  it("J1 확신이 0.5–0.8(confirm)이면 쓰지 않고 글로 한 번 묻는다 (move_ask), 같은 내용", () => {
    const direct = resolveOrganize(input("#139 Launch로"));
    const ask = resolveOrganize(input("#139 Launch로", { confirm: true }));
    expect(direct.kind).toBe("move");
    expect(ask.kind).toBe("move_ask");
    if (direct.kind === "move" && ask.kind === "move_ask") expect(ask.items).toEqual(direct.items);
  });
});

describe("빼기 (remove)", () => {
  const remove = (text: string, overrides: Partial<ResolveInput> = {}) => resolveOrganize(input(text, { judged: judged("remove"), ...overrides }));

  it("프로젝트를 말하지 않아도 확인된 멤버십이 하나면 그것", () => {
    const result = remove("#139 프로젝트에서 빼줘");
    expect(result).toMatchObject({ kind: "move", op: "remove", to: null });
    if (result.kind === "move") expect(result.items[0]).toMatchObject({ add: null, remove: { id: CTX.taskforce } });
  });

  it("프로젝트를 말하면 그것: 멤버가 아니면 쓰지 않는다", () => {
    expect(remove("#151 Launch에서 빼줘")).toMatchObject({ kind: "move", op: "remove" });
    expect(remove("#139 Launch에서 빼줘")).toMatchObject({ kind: "reply", reason: "not_member", numbers: [139], names: ["Launch"] });
  });

  it("멤버십이 0개이거나 둘 이상이고 프로젝트를 말하지 않으면 묻는다", () => {
    expect(remove("#140 빼줘")).toMatchObject({ kind: "ask", pending: { op: "remove", missing: "project" } });
    expect(remove("#151 빼줘")).toMatchObject({ kind: "ask", pending: { op: "remove", action_ids: [A151.id], missing: "project" } });
  });

  it("보관된 프로젝트에서는 빼지 않는다", () => {
    expect(remove("#139 Old에서 빼줘")).toMatchObject({ kind: "reply", reason: "context_archived" });
  });
});

describe("삭제 (delete) · 병합 (merge) 카드", () => {
  const del = (text: string, overrides: Partial<ResolveInput> = {}) => resolveOrganize(input(text, { judged: judged("delete"), ...overrides }));
  const merge = (text: string, into: { number: number | null; confidence: number } | null, overrides: Partial<ResolveInput> = {}) =>
    resolveOrganize(input(text, { judged: judged("merge", 0.95, into), ...overrides }));

  it("삭제: 이슈 1–3개는 카드, 이미 지운 것은 빼고, 모두 지웠으면 '이미 지움'", () => {
    expect(del("#141 지워줘")).toMatchObject({ kind: "delete" });
    const two = del("#141 #150 #144 지워줘");
    if (two.kind !== "delete") throw new Error("delete 아님");
    expect(two.targets.map((t) => t.number)).toEqual([141, 144]);
    expect(del("#150 지워줘")).toMatchObject({ kind: "reply", reason: "already_deleted", numbers: [150] });
    expect(del("#139 #140 #141 #144 지워줘")).toMatchObject({ kind: "reply", reason: "too_many" });
    expect(del("지워줘")).toMatchObject({ kind: "ask", pending: { op: "delete", missing: "issue" } });
  });

  it("병합: 남는 쪽은 Jev into(≥0.8)가 이긴다 — '#139에 #144 합쳐줘'는 글 순서와 반대", () => {
    const result = merge("#139에 #144 합쳐줘", { number: 139, confidence: 0.9 });
    expect(result).toMatchObject({ kind: "merge" });
    if (result.kind === "merge") {
      expect(result.into.number).toBe(139);
      expect(result.from.number).toBe(144);
    }
  });

  it("Jev into가 확신이 낮거나 없으면 '뒤에 말한 이슈'가 남는다", () => {
    for (const into of [null, { number: 139, confidence: 0.5 }, { number: null, confidence: 0.9 }]) {
      const result = merge("#144를 #139에 합쳐줘", into);
      expect(result).toMatchObject({ kind: "merge" });
      if (result.kind === "merge") expect([result.from.number, result.into.number]).toEqual([144, 139]);
    }
  });

  it("글 순서를 알 수 없으면(칩 둘) 어느 쪽을 남길지 묻는다. 이슈가 둘이 아니면 이슈를 묻고, 지운 이슈가 있으면 쓰지 않는다", () => {
    expect(merge("이 둘 합쳐줘", null, { chipActionIds: [A139.id, A144.id] })).toMatchObject({ kind: "ask", pending: { op: "merge", action_ids: [A139.id, A144.id], missing: "into" } });
    expect(merge("#139 합쳐줘", null)).toMatchObject({ kind: "ask", pending: { op: "merge", missing: "issue" } });
    expect(merge("#139 #140 #141 합쳐줘", null)).toMatchObject({ kind: "ask", pending: { missing: "issue" } });
    expect(merge("#139 #150 합쳐줘", null)).toMatchObject({ kind: "reply", reason: "issue_dropped", numbers: [150] });
  });

  it("같은 이슈를 두 번 말하면 둘이 아니다", () => {
    expect(merge("#139 #139 합쳐줘", null)).toMatchObject({ kind: "ask", pending: { missing: "issue" } });
  });
});

describe("무엇을 할지 (op)", () => {
  it("Jev가 other이거나 확신이 0.8 미만이면 묻는다 (쓰기 0)", () => {
    expect(resolveOrganize(input("#139 이거 어떻게 좀", { judged: judged("other") }))).toMatchObject({ kind: "ask", pending: { op: null, action_ids: [A139.id], missing: "op" } });
    expect(resolveOrganize(input("#139 Launch로", { judged: judged("move", 0.79) }))).toMatchObject({ kind: "ask", pending: { missing: "op" } });
    expect(resolveOrganize(input("#139 Launch로", { judged: { op: null, into: null } }))).toMatchObject({ kind: "ask", pending: { missing: "op" } });
  });
});

describe("한 번 더 묻기 (pending, 한 라운드)", () => {
  it("프로젝트를 물었고 '런치'만 답하면 앞 값에 이번 지칭만 더해 푼다", () => {
    const result = resolveOrganize(input("Launch", { pending: pending({ op: "move", action_ids: [A139.id], missing: "project" }), judged: { op: null, into: null } }));
    expect(result).toMatchObject({ kind: "move", to: { id: CTX.launch } });
    if (result.kind === "move") expect(result.items[0].action.number).toBe(139);
  });

  it("출발을 물었고 'Taskforce'만 답하면 앞 pending의 도착으로 옮긴다", () => {
    const result = resolveOrganize(
      input("Taskforce", { pending: pending({ op: "move", action_ids: [A151.id], context_id: CTX.launch, missing: "from" }), judged: { op: null, into: null } }),
    );
    expect(result).toMatchObject({ kind: "move" });
    if (result.kind === "move") {
      expect(result.to).toMatchObject({ id: CTX.launch });
      expect(result.items[0]).toMatchObject({ remove: { id: CTX.taskforce }, add: { id: CTX.launch } });
    }
  });

  it("이슈를 물었고 '#140'이라고 답하면 앞 op · 프로젝트에 더한다", () => {
    const result = resolveOrganize(input("#140", { pending: pending({ op: "move", context_id: CTX.launch, missing: "issue" }), judged: { op: null, into: null } }));
    expect(result).toMatchObject({ kind: "move", to: { id: CTX.launch } });
  });

  it("남는 쪽을 물었고 '#139'라고 답하면 그 이슈가 남는다 (정해진 값이므로 Jev 없이)", () => {
    const result = resolveOrganize(input("#139", { pending: pending({ op: "merge", action_ids: [A144.id, A139.id], missing: "into" }), judged: { op: null, into: null } }));
    expect(result).toMatchObject({ kind: "merge" });
    if (result.kind === "merge") expect([result.from.number, result.into.number]).toEqual([144, 139]);
  });

  it("이번 메시지가 자기 이슈를 말하면 새 명령이다: 앞 pending의 이슈는 쓰지 않는다 (op는 새로 읽은 것)", () => {
    const result = resolveOrganize(input("아니 #141 지워줘", { pending: pending({ op: "move", action_ids: [A139.id], context_id: CTX.launch, missing: "from" }), judged: judged("delete") }));
    expect(result).toMatchObject({ kind: "delete" });
    if (result.kind === "delete") expect(result.targets.map((t) => t.number)).toEqual([141]);
  });

  it("그래도 모자라면 다시 묻는 결과가 나온다 (한 라운드는 respond가 clarify 글로 바꾼다)", () => {
    const result = resolveOrganize(input("글쎄", { pending: pending({ op: "move", action_ids: [A139.id], missing: "project" }), judged: { op: null, into: null } }));
    expect(result).toMatchObject({ kind: "ask", pending: { missing: "project" } });
  });
});

// ─── 정리가 물은 것에 대한 짧은 답 (코디네이터 eval 반영): 코드가 정한다, J1 라벨을 믿지 않는다 ───
// 실제 모델 eval에서 "Launch"는 J1이 instruct(0.90)로, "Other"는 other(0.79)로 읽어 정리 이어가기로 오지 못했다.
describe("isOrganizeAnswer (answer-shaped 짧은 답)", () => {
  const contexts = LOOKUP.contexts.map((c) => ({ id: c.id, name: c.name }));
  const answers = (text: string, extra: Partial<Parameters<typeof isOrganizeAnswer>[0]> = {}) => isOrganizeAnswer({ text, chipActionIds: [], chipContextIds: [], contexts, ...extra });

  it("프로젝트 이름(그대로)만 · 그 이름 + 조사 · 응답 말머리만 있으면 답이다", () => {
    for (const text of ["Launch", "launch", " Launch. ", "Launch로", "Launch로요", "Launch에서", "네, Launch", "응 Launch로", "출시 준비", "출시 준비로", "Taskforce 0.2.0으로", "the Launch project", "to Launch please"]) {
      expect(answers(text), text).toBe(true);
    }
  });

  it("#번호 · 칩 지칭만 있어도 답이다 (조사 · 지시어만 곁들여도)", () => {
    for (const text of ["#144", "#139에", "#144를", "#139 #144", "그거 #144로요"]) expect(answers(text), text).toBe(true);
    expect(answers("이걸로", { chipActionIds: [A140.id] })).toBe(true);
    expect(answers("this one", { chipContextIds: [CTX.launch] })).toBe(true);
  });

  it("지칭이 하나도 없으면 답이 아니다 (이름 없는 '런치로' · 응 · 지시어만)", () => {
    for (const text of ["런치로", "응", "그걸로요", "글쎄", "Launching"]) expect(answers(text), text).toBe(false);
  });

  it("지칭이 있어도 그 밖의 말(지시 · 질문 · 정정)이 있으면 답이 아니다: J1이 정한다", () => {
    for (const text of ["Launch 일정 알려줘", "Launch 알려줘", "아니 Launch에서 빼줘", "#144 요약해줘", "move #144 to Launch", "Launch 어때?", "Launch는 어제 끝났어", "Launch로 보내줘", "아니 Launch", "no, Launch"]) {
      expect(answers(text), text).toBe(false);
    }
  });

  it("더 긴 이름 안의 짧은 일치는 이름으로 세지 않는다 (Taskforce 0.2.0 안의 Taskforce가 남지 않는다) · 인용한 줄은 보지 않는다", () => {
    expect(answers("Taskforce 0.2.0")).toBe(true);
    expect(answers("> Launch로 옮겨줘\nLaunch")).toBe(true);
    expect(answers("> Launch")).toBe(false);
  });

  it("긴 글은 답이 아니다", () => {
    expect(answers(`Launch ${"로 ".repeat(60)}`)).toBe(false);
  });
});

// 독립 검토(Astra) 반영: 질문에 대한 단순한 답과 정정 · 새 지시를 구분하고, 병합 대상 질문의 답은 앞 대상과 합치고, 답한 출발을 실제 소속으로 검증한다
describe("질문에 대한 답 · 정정 · 새 지시 (검토 P1-2)", () => {
  const asked = pending({ op: "move", action_ids: [A151.id], missing: "project" });

  it("프로젝트 이름만 답하면(Jev op가 other이거나 확실하지 않거나 같은 op) 앞 계획을 채운다", () => {
    for (const op of [judged("other"), judged("move", 0.6), judged("move"), judged("remove", 0.7), { op: null, into: null }]) {
      const result = resolveOrganize(input("Launch", { pending: pending({ op: "move", action_ids: [A139.id], missing: "project" }), judged: op }));
      expect(result, JSON.stringify(op)).toMatchObject({ kind: "move", op: "move", to: { id: CTX.launch } });
    }
  });

  it("'아니 Launch에서 빼줘'는 앞 op(옮기기)와 다른 op(빼기)로 읽히면 새로 푼다: 앞 이슈에서 Launch를 뺀다 (Launch로 옮기지 않는다)", () => {
    const result = resolveOrganize(input("아니 Launch에서 빼줘", { pending: asked, judged: judged("remove") }));
    expect(result).toMatchObject({ kind: "move", op: "remove", to: null });
    if (result.kind !== "move") throw new Error("move 아님");
    expect(result.items).toHaveLength(1);
    expect(result.items[0]).toMatchObject({ add: null, remove: { id: CTX.launch } });
    expect(result.items[0].action.id).toBe(A151.id);
  });

  it("정정이 다른 op로 바뀌면 앞 계획의 프로젝트도 이어받지 않는다 (프로젝트를 말하지 않은 '그냥 지워줘'는 지우기 카드)", () => {
    const result = resolveOrganize(input("아니 그냥 지워줘", { pending: pending({ op: "move", action_ids: [A140.id], context_id: CTX.launch, missing: "from" }), judged: judged("delete") }));
    expect(result).toMatchObject({ kind: "delete" });
    if (result.kind === "delete") expect(result.targets.map((t) => t.number)).toEqual([140]);
  });

  it("남는 쪽을 물은 뒤의 '아니 #141 지워줘'는 새 지시다: 앞 둘과 합쳐 셋을 지우지 않고 #141만 지우는 카드", () => {
    const result = resolveOrganize(input("아니 #141 지워줘", { pending: pending({ op: "merge", action_ids: [A144.id, A139.id], missing: "into" }), judged: judged("delete") }));
    expect(result).toMatchObject({ kind: "delete" });
    if (result.kind === "delete") expect(result.targets.map((t) => t.number)).toEqual([141]);
  });
});

describe("병합 대상 질문의 답은 앞 대상과 합친다 (검토 P2-6, 계약 Q10)", () => {
  const asked = pending({ op: "merge", action_ids: [A139.id], missing: "issue" });

  it("'#139 합쳐줘' → 질문 → '#144' = [139, 144]: Jev into가 정하는 쪽이 남는 카드", () => {
    const result = resolveOrganize(input("#144", { pending: asked, judged: judged("other", 0.9, { number: 139, confidence: 0.9 }) }));
    expect(result).toMatchObject({ kind: "merge" });
    if (result.kind === "merge") expect([result.from.number, result.into.number]).toEqual([144, 139]);
  });

  it("Jev가 정하지 못하면 이번 글에서 말한 쪽이 뒤에 말한 것이라 남는다 (앞 질문에서 넘어온 이슈는 이번 글보다 앞)", () => {
    const result = resolveOrganize(input("#144", { pending: asked, judged: judged("merge") }));
    expect(result).toMatchObject({ kind: "merge" });
    if (result.kind === "merge") expect([result.from.number, result.into.number]).toEqual([139, 144]);
  });

  it("앞 이슈는 칩이어도 같다. 같은 이슈를 다시 답하면 둘이 아니라서 다시 이슈를 묻는다", () => {
    expect(resolveOrganize(input("이거랑", { pending: asked, chipActionIds: [A144.id], judged: judged("other", 0.9, { number: 139, confidence: 0.9 }) }))).toMatchObject({ kind: "merge" });
    expect(resolveOrganize(input("#139", { pending: asked, judged: judged("other") }))).toMatchObject({ kind: "ask", pending: { op: "merge", missing: "issue" } });
  });

  it("이번 메시지가 둘을 직접 말했으면 새 지시라서 앞 이슈를 합치지 않는다. 다른 op의 정정도 마찬가지", () => {
    const two = resolveOrganize(input("#140 #141 합쳐줘", { pending: asked, judged: judged("merge") }));
    expect(two).toMatchObject({ kind: "merge" });
    if (two.kind === "merge") expect([two.from.number, two.into.number]).toEqual([140, 141]);
    const fix = resolveOrganize(input("아니 #141 지워줘", { pending: asked, judged: judged("delete") }));
    expect(fix).toMatchObject({ kind: "delete" });
    if (fix.kind === "delete") expect(fix.targets.map((t) => t.number)).toEqual([141]);
  });
});

describe("답한 출발 프로젝트 검증 (검토 P2-5)", () => {
  // A151은 Launch와 Taskforce에 있고, 도착은 Taskforce 0.2.0 — 출발이 둘이라 어느 쪽인지 물었다
  const asked = pending({ op: "move", action_ids: [A151.id], context_id: CTX.taskforce2, missing: "from" });

  it("실제 소속을 답하면 그 소속만 빼고 도착을 더한다", () => {
    const result = resolveOrganize(input("Launch", { pending: asked, judged: { op: null, into: null } }));
    expect(result).toMatchObject({ kind: "move" });
    if (result.kind === "move") expect(result.items[0]).toMatchObject({ remove: { id: CTX.launch }, add: { id: CTX.taskforce2 } });
  });

  it("소속이 아닌 프로젝트를 답하면 쓰지 않고(도착만 더하지 않고) 실제 소속을 후보로 같은 것을 다시 묻는다", () => {
    const result = resolveOrganize(input("출시 준비", { pending: asked, judged: { op: null, into: null } }));
    expect(result).toEqual({
      kind: "ask",
      pending: { state: "pending", op: "move", action_ids: [A151.id], context_id: CTX.taskforce2, missing: "from" },
      candidates: [
        { id: CTX.launch, name: "Launch" },
        { id: CTX.taskforce, name: "Taskforce" },
      ],
      again: true,
    });
  });

  it("실제 다른 소속이 하나도 없으면(그 사이 바뀜) 다시 묻지 않고 그 프로젝트에 없다고 답한다", () => {
    const result = resolveOrganize(input("출시 준비", { pending: pending({ op: "move", action_ids: [A140.id], context_id: CTX.launch, missing: "from" }), judged: { op: null, into: null } }));
    expect(result).toMatchObject({ kind: "reply", reason: "not_member", numbers: [140], names: ["출시 준비"] });
  });

  it("여러 이슈 중 하나라도 소속이 아니면 아무것도 쓰지 않는다 (맞는 이슈만 옮기지 않는다)", () => {
    const result = resolveOrganize(input("Taskforce", { pending: pending({ op: "move", action_ids: [A151.id, A139.id, A140.id], context_id: CTX.launch, missing: "from" }), judged: { op: null, into: null } }));
    expect(result).toMatchObject({ kind: "ask", again: true, pending: { missing: "from", context_id: CTX.launch } });
  });

  it("이미 도착에 있는 이슈는 답한 출발이 소속이 아니어도 막지 않는다 (옮길 것이 없으면 이미 있음)", () => {
    const result = resolveOrganize(input("출시 준비", { pending: pending({ op: "move", action_ids: [A151.id], context_id: CTX.launch, missing: "from" }), judged: { op: null, into: null } }));
    expect(result).toMatchObject({ kind: "reply", reason: "already_there", numbers: [151] });
  });
});

// ─── 삭제 · 병합 카드의 쓰기 계획 (D4c-2): 확인(버튼 · 글)이 삭제 경로와 같은 쓰기를 만든다 ───
describe("삭제 · 병합 카드 쓰기 계획", () => {
  const NOW = new Date("2026-10-15T01:00:00.000Z");
  const USER_ID = "11111111-0000-4000-8000-000000000001";
  const newId = () => {
    let i = 0;
    return () => `eeeeeeee-0000-4000-8000-${String(++i).padStart(12, "0")}`;
  };
  const stored = (a: OrganizeLookup["actions"][number], over: Partial<StoredTarget["row"]> = {}): StoredTarget => ({
    row: { title: a.title, confirm_reasons: [], needs_confirmation: false, version: a.version, status: a.status, started_at: null, ...over },
    // 이슈를 만든 때의 사용자 Claim (지금보다 앞이어야 새 Claim이 이긴다)
    claims: userClaims([{ field: "scope", value: a.title }, { field: "owner", value: "me" }, { field: "status", value: a.status }], new Date(NOW.getTime() - 86_400_000), newId()),
  });
  const current = (...entries: [OrganizeLookup["actions"][number], Partial<StoredTarget["row"]>?][]) => new Map(entries.map(([a, over]) => [a.id, stored(a, over)]));
  const del = deletePayload([A141, A144]);
  const merge = mergePayload(A144, A139);

  it("대상: 삭제는 카드의 이슈들, 병합은 [사라지는 쪽, 남는 쪽]", () => {
    expect(cardTargets(del).map((t) => t.number)).toEqual([141, 144]);
    expect(cardTargets(merge).map((t) => t.number)).toEqual([144, 139]);
  });

  it("낡음: 모든 대상의 version이 카드가 본 값 그대로이고 지운 것이 없어야 신선하다 (updated_at이 아니라 version)", () => {
    expect(cardIsFresh(del, current([A141], [A144]))).toBe(true);
    expect(cardIsFresh(del, current([A141], [A144, { version: 3 }]))).toBe(false);
    expect(cardIsFresh(del, current([A141], [A144, { status: "dropped" }]))).toBe(false);
    expect(cardIsFresh(del, current([A141]))).toBe(false);
    expect(cardIsFresh(merge, current([A144], [A139]))).toBe(true);
    expect(cardIsFresh(merge, current([A144], [A139, { status: "dropped" }]))).toBe(false);
    expect(cardIsFresh(merge, current([A144, { version: 9 }], [A139]))).toBe(false);
  });

  it("삭제: 대상마다 삭제 경로와 같은 쓰기 — 읽은 version 조건, 사용자 Claim status dropped(지금 시각), user_deleted 이벤트(before/after status), 확인 이유 비움", () => {
    const writes = cardWrites(USER_ID, del, current([A141], [A144]), NOW, newId());
    expect(writes.map((w) => [w.action_id, w.expected_version])).toEqual([[A141.id, 2], [A144.id, 2]]);
    for (const w of writes) {
      expect(w.action).toMatchObject({ status: "dropped", needs_confirmation: false, confirm_reasons: [] });
      expect(w.claims).toEqual([expect.objectContaining({ user_id: USER_ID, action_id: w.action_id, source_id: null, quote: null, field: "status", value: "dropped", origin: "user", channel: "note", state: "active", occurred_at: NOW.toISOString() })]);
      expect(w.events).toEqual([{ type: "user_deleted", before: { status: "open" }, after: { status: "dropped" }, rule: "user", actor: "user", source_id: null }]);
    }
  });

  it("병합: 사라지는 쪽은 삭제와 같은 쓰기에 이벤트만 user_merged(after.into), 남는 쪽은 확인만(값 · Claim · 이벤트 0, 읽은 version 조건)", () => {
    const writes = cardWrites(USER_ID, merge, current([A144], [A139]), NOW, newId());
    expect(writes).toHaveLength(2);
    const [gone, stays] = writes;
    expect(gone.action_id).toBe(A144.id);
    expect(gone.action).toMatchObject({ status: "dropped" });
    expect(gone.events).toEqual([{ type: "user_merged", before: { status: "open" }, after: { status: "dropped", into: A139.id }, rule: "user", actor: "user", source_id: null }]);
    expect(stays).toEqual({ action_id: A139.id, expected_version: 2, action: null, claims: [], events: [] });
    // 삭제와 같은 값
    const asDelete = cardWrites(USER_ID, deletePayload([A144]), current([A144]), NOW, newId())[0];
    expect({ ...gone, events: [] }).toEqual({ ...asDelete, events: [] });
  });

  it("다시 낼 카드: 지금 기록에서 살아 있는 대상으로. 모두 지웠으면(삭제) · 한쪽이라도 지웠으면(병합) 없다. 내용 hash가 맞고 asks confirm", () => {
    const next = newId();
    const lookup = (actions: OrganizeLookup["actions"]): OrganizeLookup => ({ ...LOOKUP, actions });
    const redo = reissuedCard("ko", del, lookup([{ ...A141, version: 5 }, A144]), next);
    expect(redo).not.toBeNull();
    expect(redo!.text).toBe("#141 · #144을(를) 지울까요?");
    expect(redo!.proposal).toMatchObject({ kind: "delete", state: "open", payload_hash: payloadHash(redo!.content.proposal!) });
    expect(redo!.content).toMatchObject({ asks: "confirm", proposal: { kind: "delete", targets: [{ number: 141, version: 5 }, { number: 144, version: 2 }] } });
    // 하나만 지웠으면 남은 것만
    const partial = reissuedCard("en", del, lookup([A141, { ...A144, status: "dropped" }]), next);
    expect(partial!.content.proposal).toMatchObject({ targets: [{ number: 141 }] });
    expect(partial!.text).toBe("Delete #141?");
    expect(reissuedCard("ko", del, lookup([{ ...A141, status: "dropped" }, { ...A144, status: "dropped" }]), next)).toBeNull();
    const m = reissuedCard("ko", merge, lookup([A144, { ...A139, version: 4 }]), next);
    expect(m!.content.proposal).toMatchObject({ kind: "merge", from: { number: 144 }, into: { number: 139, version: 4 } });
    expect(reissuedCard("ko", merge, lookup([A144, { ...A139, status: "dropped" }]), next)).toBeNull();
    expect(reissuedCard("ko", merge, lookup([A144]), next)).toBeNull();
  });

  it("문구와 확인 event 내용: 지웠어요 · 합쳤어요, organize.state deleted · merged", () => {
    expect(cardAskText("ko", del)).toBe("#141 · #144을(를) 지울까요?");
    expect(cardAskText("en", merge)).toBe("Merge #144 into #139?");
    expect(cardAskText("ko", merge)).toBe("#144을(를) #139에 합칠까요?");
    expect(cardDoneText("ko", del)).toBe("지웠어요: #141 · #144");
    expect(cardDoneText("en", merge)).toBe("Merged #144 into #139");
    expect(cardDoneContent("ko", del)).toMatchObject({ segments: [{ text: "지웠어요: #141 · #144", tier: "T1" }], citations: [], proposal: null, asks: null, organize: { state: "deleted", action_ids: [A141.id, A144.id] } });
    expect(cardDoneContent("en", merge).organize).toEqual({ state: "merged", from_action_id: A144.id, into_action_id: A139.id });
  });
});

// ─── Jev organize-v2 · v3 질문 (eval · 검토 반영) ───
// org-merge-particle-ko("#139에 #144 합쳐줘")에서 남는 쪽을 #144로 골랐다: v1은 두 선택지 설명이 똑같아 Jev가 고를 근거가 없었다 (v2).
// v3: 질문에 대한 단순한 답("Launch")을 Jev가 새 지시(옮기기)로 읽어 앞 계획(빼기)을 뒤집지 않게, 이름만 말한 글은 other라고 알린다.
describe("organizeIntoQuestion (organize-v2) · ORGANIZE_OP_QUESTION (organize-v3)", () => {
  it("op 질문은 지시 없이 프로젝트나 이슈 이름만 말한 글(질문에 대한 답)은 other라고 알린다 — 선택지 키는 그대로", () => {
    const question = ORGANIZE_OP_QUESTION;
    expect(question.type).toBe("choice");
    expect(question.instructions).toMatch(/only names a project or an issue/);
    expect(question.instructions).toMatch(/answer to a question Taskforce (just )?asked/);
    expect(question.instructions).toMatch(/the answer is other/);
    expect(question.instructions).toMatch(/quoted|forwarded/i);
    if (question.type === "choice") expect(Object.keys(question.criteria)).toEqual(["move", "remove", "delete", "merge", "other"]);
  });

  it("버전이 올랐다. 선택지는 이슈 표시(#번호)이고 설명은 선택지마다 그 이슈가 남는 쪽임을 말한다 (서로 다르다)", () => {
    expect(ORGANIZE_PROMPT_VERSION).toBe("organize-v3");
    const question = organizeIntoQuestion(["#144", "#139"]);
    expect(question.type).toBe("choice");
    if (question.type !== "choice") throw new Error("choice 아님");
    expect(Object.keys(question.criteria)).toEqual(["#144", "#139"]);
    expect(question.criteria["#144"]).toContain("#144");
    expect(question.criteria["#139"]).toContain("#139");
    expect(question.criteria["#144"]).not.toBe(question.criteria["#139"]);
  });

  it("지시문이 받는 쪽(남는 쪽)을 가르는 말을 밝힌다: 한국어 에 · 에다 · 으로 · 로, 영어 into, 목적격 를 · 을은 합쳐 사라지는 쪽, 표시가 없으면 마지막에 말한 이슈. 인용은 요청이 아니다", () => {
    const question = organizeIntoQuestion(["#139", "#144"]);
    const text = question.instructions;
    for (const marker of ["에", "에다", "으로", "into", "를", "last"]) expect(text, marker).toContain(marker);
    expect(text).toContain("#139에 #144 합쳐줘");
    expect(text).toContain("merge #144 into #139");
    expect(text).toMatch(/quoted|forwarded/i);
  });

  it("Jev state는 메시지와 이슈 표시뿐 (제목 · 프로젝트 이름 없음), op 선택지는 그대로", () => {
    expect(buildOrganizeState({ message: "#139에 #144 합쳐줘", issues: ["#139", "#144"] })).toEqual({ message: "#139에 #144 합쳐줘", issues: ["#139", "#144"] });
    expect(Object.keys(ORGANIZE_OP_CRITERIA)).toEqual(["move", "remove", "delete", "merge", "other"]);
  });
});
