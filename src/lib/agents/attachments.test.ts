import { describe, expect, it } from "vitest";

import type { Attachment } from "@/lib/api/contract";

import { agentSelected, attachmentsFromLegacyRefs, checkAttachments, normalizeAttachments, taskforceSelected } from "./attachments";
import { fakeAdmin } from "./fake-admin";

const USER = "10000000-0000-4000-8000-000000000001";
const A = "aaaaaaaa-0000-4000-8000-000000000001";
const B = "bbbbbbbb-0000-4000-8000-000000000002";
const C = "cccccccc-0000-4000-8000-000000000003";
const chip = (kind: Attachment["kind"], id: string, origin: Attachment["origin"] = "added"): Attachment => ({ kind, id, origin });

describe("normalizeAttachments (계약 2.2): 소문자 · 중복 제거 · 정렬, auto와 added가 같이 오면 added", () => {
  it("빠진 목록은 빈 목록", () => {
    expect(normalizeAttachments(undefined)).toEqual([]);
    expect(normalizeAttachments([])).toEqual([]);
  });

  it("대소문자만 다른 같은 (kind, id)는 하나로 합쳐 소문자로 둔다", () => {
    expect(normalizeAttachments([chip("action", A.toUpperCase()), chip("action", A)])).toEqual([chip("action", A)]);
  });

  it("같은 (kind, id)가 auto와 added로 함께 오면 어느 순서든 added 하나", () => {
    expect(normalizeAttachments([chip("run", A, "auto"), chip("run", A, "added")])).toEqual([chip("run", A, "added")]);
    expect(normalizeAttachments([chip("run", A, "added"), chip("run", A, "auto")])).toEqual([chip("run", A, "added")]);
    expect(normalizeAttachments([chip("run", A, "auto"), chip("run", A, "auto")])).toEqual([chip("run", A, "auto")]);
  });

  it("같은 id라도 종류가 다르면 다른 칩이다. 순서는 종류 → id", () => {
    expect(normalizeAttachments([chip("source", C), chip("action", B), chip("action", A), chip("context", A)])).toEqual([
      chip("action", A), chip("action", B), chip("context", A), chip("source", C),
    ]);
  });

  it("입력 순서가 달라도 같은 목록이 나온다 (같은 제출 비교의 근거)", () => {
    const one = normalizeAttachments([chip("action", A), chip("context", B, "auto"), chip("run", C)]);
    const two = normalizeAttachments([chip("run", C), chip("context", B, "auto"), chip("action", A.toUpperCase())]);
    expect(two).toEqual(one);
  });
});

describe("옛 refs → 칩", () => {
  it("action · run · artifact id는 모두 added 칩이 된다 (새 앱은 attachments만 보낸다)", () => {
    expect(attachmentsFromLegacyRefs({ action_ids: [A], run_ids: [B], artifact_ids: [C] })).toEqual([chip("action", A), chip("run", B), chip("artifact", C)]);
    expect(attachmentsFromLegacyRefs(undefined)).toEqual([]);
    expect(attachmentsFromLegacyRefs({})).toEqual([]);
  });
});

describe("selected 모양 (OD-3 · OD-5)", () => {
  const chips = normalizeAttachments([chip("action", A), chip("action", B, "auto"), chip("context", C), chip("context", A, "auto"), chip("run", B), chip("artifact", C), chip("source", A), chip("agent_session", B)]);

  it("에이전트 대상: added action · context id + 정규화한 칩 전체 (auto는 id 목록에 없다)", () => {
    expect(agentSelected(chips)).toEqual({ action_ids: [A], context_ids: [C], attachments: chips });
    expect(agentSelected([])).toEqual({ action_ids: [], context_ids: [], attachments: [] });
  });

  it("taskforce 대상: 기존 모양 + attachments. added action · run · (execution) artifact만 id 목록에 넣는다", () => {
    expect(taskforceSelected(chips, [C])).toEqual({ action_ids: [A], run_ids: [B], artifact_ids: [C], attachments: chips });
    // 에이전트 산출물 id는 taskforce의 규칙 1 대상이 아니다 (저장만)
    expect(taskforceSelected(chips, [])).toMatchObject({ artifact_ids: [], attachments: chips });
  });

  it("칩이 없으면 taskforce selected에 attachments 키를 만들지 않는다 (옛 제출과 같은 제출로 비교된다)", () => {
    expect(taskforceSelected([], [])).toEqual({ action_ids: [], run_ids: [], artifact_ids: [] });
    expect(Object.keys(taskforceSelected([], []))).not.toContain("attachments");
  });
});

describe("checkAttachments: 종류별 소유 확인 (AC-1)", () => {
  const tables = () => ({
    actions: [{ id: A, user_id: USER }, { id: B, user_id: "other" }],
    work_contexts: [{ id: A, user_id: USER }],
    agent_sessions: [{ id: A, user_id: USER }],
    execution_runs: [{ id: A, user_id: USER }],
    execution_artifacts: [{ id: B, user_id: USER }],
    agent_artifacts: [{ id: C, user_id: USER }],
    sources: [{ id: A, user_id: USER, raw_text_purge_reason: null }, { id: B, user_id: USER, raw_text_purge_reason: "disconnected" }, { id: C, user_id: USER, raw_text_purge_reason: "retention" }],
  });

  it("내 것이면 missing 없음. 이 사용자의 행만 센다 (user_id로 좁힌다)", async () => {
    const fake = fakeAdmin({ tables: tables() });
    const chips = normalizeAttachments([chip("action", A), chip("context", A), chip("agent_session", A), chip("run", A), chip("source", A)]);
    const result = await checkAttachments(fake.admin, USER, chips);
    expect(result).toEqual({ missing: [], purged: [], executionArtifactIds: [] });
    for (const call of fake.calls) expect(call.filters).toContainEqual(["user_id", "eq", USER]);
  });

  it.each(["action", "context", "agent_session", "run", "artifact", "source"] as const)("%s 칩: 남의 · 없는 id는 missing", async (kind) => {
    const fake = fakeAdmin({ tables: tables() });
    const unknown = "dddddddd-0000-4000-8000-00000000000d";
    const result = await checkAttachments(fake.admin, USER, [chip(kind, unknown)]);
    expect(result.missing).toEqual([chip(kind, unknown)]);
  });

  it("남의 action은 missing이다 (같은 id가 다른 사용자 행으로 있어도)", async () => {
    const fake = fakeAdmin({ tables: tables() });
    expect((await checkAttachments(fake.admin, USER, [chip("action", B)])).missing).toEqual([chip("action", B)]);
  });

  it("artifact 칩은 두 표(execution_artifacts · agent_artifacts) 어느 쪽 id든 받는다 (OD-24). execution 쪽 id를 따로 돌려준다", async () => {
    const fake = fakeAdmin({ tables: tables() });
    const result = await checkAttachments(fake.admin, USER, [chip("artifact", B), chip("artifact", C)]);
    expect(result.missing).toEqual([]);
    expect(result.executionArtifactIds).toEqual([B]);
  });

  it("Slack 연결 해제로 글이 지워진 source는 받고 purged로 표시한다 (OD-23). 90일 보관 정리는 해당 없음", async () => {
    const fake = fakeAdmin({ tables: tables() });
    const result = await checkAttachments(fake.admin, USER, [chip("source", B), chip("source", C), chip("source", A)]);
    expect(result.missing).toEqual([]);
    expect(result.purged).toEqual([chip("source", B)]);
  });

  it("대소문자 다른 id도 같은 행이다", async () => {
    const fake = fakeAdmin({ tables: tables() });
    expect((await checkAttachments(fake.admin, USER, [chip("action", A.toUpperCase())])).missing).toEqual([]);
  });

  it("칩이 없는 종류는 묻지 않는다 (칩이 없으면 질의 0)", async () => {
    const fake = fakeAdmin({ tables: tables() });
    await checkAttachments(fake.admin, USER, []);
    expect(fake.calls).toEqual([]);
    await checkAttachments(fake.admin, USER, [chip("run", A)]);
    expect(fake.calls.map((call) => call.target)).toEqual(["execution_runs"]);
  });

  it("DB 오류는 그대로 던진다", async () => {
    const fake = fakeAdmin({ tables: tables(), fail: { "actions.select": { code: "XX000", message: "db" } } });
    await expect(checkAttachments(fake.admin, USER, [chip("action", A)])).rejects.toThrow("db");
  });
});
