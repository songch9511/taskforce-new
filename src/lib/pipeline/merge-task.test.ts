import { describe, expect, it } from "vitest";

import { EMBEDDING_DIMENSIONS } from "@/lib/ai/embed";

import type { Decide } from "./judge";
import { InMemoryActionStore, type MergeDeps } from "./merge";
import { InMemoryTaskLinks, mergeTask, type TaskInput } from "./merge-task";
import { resolveAction } from "./resolve";
import type { TaskSnapshot } from "./structured";

const identity = { name: "청혁", aliases: [], emails: [] };
const vector = () => {
  const v = new Array(EMBEDDING_DIMENSIONS).fill(0);
  v[0] = 1;
  return v;
};

/** 기존 Action이 있으면 relation을 답하는 가짜 Jev. 몇 번 불렸는지 센다. */
function deps(relation: "new" | "same_restated" = "new", probability = 0.9) {
  let n = 0;
  const calls = { decide: 0 };
  const decide: Decide = async (request) => {
    calls.decide++;
    const state = request.state as { existing: { key: string }[] };
    const target = state.existing[0]?.key ?? "none";
    return {
      model: "jev-test",
      answers: {
        relation: { type: "choice", choice: relation, probabilities: { [relation]: probability } },
        target: { type: "choice", choice: target, probabilities: { [target]: probability } },
      },
    };
  };
  const d: MergeDeps = { embed: async (texts) => texts.map(vector), decide, newId: () => `c${++n}` };
  return { d, calls };
}

const snap = (over: Partial<TaskSnapshot> = {}): TaskSnapshot => ({
  title: "UI 레이아웃 이미지 보내기",
  assignees: ["청혁"],
  owner: "me",
  due: "2026-09-30",
  status: "open",
  statusLabel: "Not started",
  ...over,
});

const at = (day: string) => new Date(`2026-09-${day}T10:00:00+09:00`);
const task = (snapshot: TaskSnapshot, prev: TaskSnapshot | null, day: string, editedByUser = false): TaskInput => ({
  externalId: "page-1",
  snapshot,
  prev,
  edit: { editedByUser, occurredAt: at(day) },
});

describe("mergeTask", () => {
  it("처음 보는 내 할 일은 Action을 만들고 연결해 둔다", async () => {
    const store = new InMemoryActionStore();
    const links = new InMemoryTaskLinks(() => store.all());
    const outcome = await mergeTask(store, links, task(snap(), null, "22"), { id: "s1", occurredAt: at("22") }, identity, deps().d);

    expect(outcome).toMatchObject({ relation: "new", changes: ["scope", "owner", "due", "status"] });
    const [action] = store.all();
    expect(links.links.get("page-1")).toBe(action.id);
    expect(action.evidence).toEqual([{ sourceId: "s1", quote: "# UI 레이아웃 이미지 보내기\n담당: 청혁\n기한: 2026-09-30\n상태: Not started", role: "created" }]);
    const state = resolveAction(action.claims);
    expect([state.owner.value, state.due.value, state.status.value]).toEqual(["me", "2026-09-30", "open"]);
  });

  it("이후 버전은 매칭 없이 바뀐 필드만 붙인다: 팀이 완료로 바꾸면 닫힌다", async () => {
    const store = new InMemoryActionStore();
    const links = new InMemoryTaskLinks(() => store.all());
    const { d, calls } = deps();
    await mergeTask(store, links, task(snap(), null, "22"), { id: "s1", occurredAt: at("22") }, identity, d);
    const decideCalls = calls.decide;

    const done = snap({ status: "done", statusLabel: "Done" });
    const outcome = await mergeTask(store, links, task(done, snap(), "25"), { id: "s2", occurredAt: at("25") }, identity, d);

    expect(outcome).toMatchObject({ relation: "linked", changes: ["status"] });
    expect(calls.decide).toBe(decideCalls);
    const [action] = store.all();
    expect(action.evidence.at(-1)).toEqual({ sourceId: "s2", quote: "상태: Done", role: "completed" });
    expect(resolveAction(action.claims).status.value).toBe("done");
  });

  it("내가 Notion에서 기한을 늦추면 반영되고(tracker), 팀원이 늦춘 것도 반영된다", async () => {
    const store = new InMemoryActionStore();
    const links = new InMemoryTaskLinks(() => store.all());
    const { d } = deps();
    await mergeTask(store, links, task(snap(), null, "22"), { id: "s1", occurredAt: at("22") }, identity, d);

    await mergeTask(store, links, task(snap({ due: "2026-10-02" }), snap(), "23", true), { id: "s2", occurredAt: at("23") }, identity, d);
    expect(resolveAction(store.all()[0].claims).due).toMatchObject({ value: "2026-10-02", reason: "사용자가 할 일 도구에서 정함" });

    await mergeTask(store, links, task(snap({ due: "2026-10-06" }), snap({ due: "2026-10-02" }), "24"), { id: "s3", occurredAt: at("24") }, identity, d);
    expect(resolveAction(store.all()[0].claims).due.value).toBe("2026-10-06");
  });

  it("처음 보는데 내 열린 할 일이 아니면 아무것도 만들지 않는다", async () => {
    const store = new InMemoryActionStore();
    const links = new InMemoryTaskLinks(() => store.all());
    for (const s of [snap({ owner: "other", assignees: ["Chan"] }), snap({ status: "done", statusLabel: "Done" })]) {
      expect((await mergeTask(store, links, task(s, null, "22"), { id: "s1", occurredAt: at("22") }, identity, deps().d)).relation).toBe("skipped");
    }
    expect(store.all()).toHaveLength(0);
    expect(links.links.size).toBe(0);
  });

  const meetingAction = (store: InMemoryActionStore) =>
    store.create({
      title: "UI 레이아웃 이미지 검토 요청",
      counterpart: null,
      embedding: vector(),
      claims: [],
      evidence: [{ sourceId: "m1", quote: "Send UI layout image for review", role: "created" }],
      confirmReasons: ["판정 확인: NOT_MY_ACTION"],
    });

  it("회의에서 이미 생긴 같은 일이면 그 Action에 붙이고 이어 둔다", async () => {
    const store = new InMemoryActionStore();
    const meeting = await meetingAction(store);
    const links = new InMemoryTaskLinks(() => store.all());
    const outcome = await mergeTask(store, links, task(snap(), null, "22"), { id: "s1", occurredAt: at("22") }, identity, deps("same_restated", 0.9).d);

    expect(outcome).toMatchObject({ relation: "duplicate", actionId: meeting.id });
    expect(store.all()).toHaveLength(1);
    expect(links.links.get("page-1")).toBe(meeting.id);
    expect(resolveAction(meeting.claims).owner.value).toBe("me");
  });

  it("같은 일인지 확신이 낮으면 합치지 않고 따로 만든 뒤 중복일 수 있다고 확인을 받는다", async () => {
    const store = new InMemoryActionStore();
    const meeting = await meetingAction(store);
    const links = new InMemoryTaskLinks(() => store.all());
    const outcome = await mergeTask(store, links, task(snap(), null, "22"), { id: "s1", occurredAt: at("22") }, identity, deps("same_restated", 0.5).d);

    expect(outcome.relation).toBe("new");
    expect(store.all()).toHaveLength(2);
    const created = store.all()[1];
    expect(links.links.get("page-1")).toBe(created.id);
    expect(created.confirmReasons).toEqual(["중복 확인 (50%): UI 레이아웃 이미지 검토 요청"]);
    expect(meeting.claims).toEqual([]);
  });

  it("사용자가 앱에서 지운 일은 Notion이 바뀌어도 되살리지 않는다", async () => {
    const store = new InMemoryActionStore();
    const links = new InMemoryTaskLinks(() => store.all());
    const { d } = deps();
    await mergeTask(store, links, task(snap(), null, "22"), { id: "s1", occurredAt: at("22") }, identity, d);
    const [action] = store.all();
    action.claims.push({ ...action.claims.find((c) => c.field === "status")!, id: "deleted", value: "dropped", origin: "user", occurredAt: at("23") });

    const done = snap({ status: "done", statusLabel: "Done", due: "2026-10-09" });
    const outcome = await mergeTask(store, links, task(done, snap(), "24"), { id: "s2", occurredAt: at("24") }, identity, d);
    expect(outcome.changes).toEqual([]);
    expect(resolveAction(action.claims).status.value).toBe("dropped");
  });

  it("닫힌 일에도 바뀐 값을 쌓아 두어, 다시 열리면 그동안 바뀐 기한이 살아 있다", async () => {
    const store = new InMemoryActionStore();
    const links = new InMemoryTaskLinks(() => store.all());
    const { d } = deps();
    const done = snap({ status: "done", statusLabel: "Done" });
    await mergeTask(store, links, task(snap(), null, "22"), { id: "s1", occurredAt: at("22") }, identity, d);
    await mergeTask(store, links, task(done, snap(), "23"), { id: "s2", occurredAt: at("23") }, identity, d);

    const moved = snap({ status: "done", statusLabel: "Done", due: "2026-10-20" });
    expect((await mergeTask(store, links, task(moved, done, "24"), { id: "s3", occurredAt: at("24") }, identity, d)).changes).toEqual(["due"]);
    const reopened = snap({ statusLabel: "Current", due: "2026-10-20" });
    expect((await mergeTask(store, links, task(reopened, moved, "25"), { id: "s4", occurredAt: at("25") }, identity, d)).changes).toEqual(["status"]);

    const state = resolveAction(store.all()[0].claims);
    expect([state.status.value, state.due.value]).toEqual(["open", "2026-10-20"]);
  });

  it("Action을 만든 뒤 연결 직전에 멈췄던 원문을 다시 처리하면 새로 만들지 않고 그 Action에 잇는다", async () => {
    const store = new InMemoryActionStore();
    const { d } = deps();
    await mergeTask(store, new InMemoryTaskLinks(() => store.all()), task(snap(), null, "22"), { id: "s1", occurredAt: at("22") }, identity, d);
    const fresh = new InMemoryTaskLinks(() => store.all()); // 연결을 잃은 상태
    const outcome = await mergeTask(store, fresh, task(snap(), null, "22"), { id: "s1", occurredAt: at("22") }, identity, d);
    expect(outcome.relation).toBe("linked");
    expect(store.all()).toHaveLength(1);
    expect(fresh.links.get("page-1")).toBe(store.all()[0].id);
  });
});
