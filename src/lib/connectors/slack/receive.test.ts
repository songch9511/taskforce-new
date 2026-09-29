import { describe, expect, it } from "vitest";

import type { PendingSlackMessage, SlackEventCallback } from "./events";
import { receiveSlackEvent, type SlackConnectionRef, type SlackReceiveDeps } from "./receive";

const ALICE: SlackConnectionRef = { id: "conn-a", userId: "user-a", slackUserId: "U_A", connectedAt: new Date("2026-10-01T00:00:00Z") };
const BOB: SlackConnectionRef = { id: "conn-b", userId: "user-b", slackUserId: "U_B", connectedAt: new Date("2026-10-01T00:00:00Z") };

function fakeDeps(connections: SlackConnectionRef[], over: Partial<SlackReceiveDeps> = {}) {
  const log = {
    stored: [] as [string, PendingSlackMessage][],
    tracked: [] as [string, string, string][],
    edited: [] as string[],
    deleted: [] as { ts: string; createIfMissing: boolean }[],
    revoked: [] as { teamId: string; users: string[] | null; before: Date }[],
    authorizationCalls: 0,
  };
  const deps: SlackReceiveDeps = {
    connectionsForTeam: async () => connections,
    consented: async () => true,
    authorizedUsers: async () => {
      log.authorizationCalls++;
      return connections.map((c) => c.slackUserId);
    },
    isThreadTracked: async () => false,
    storeMessage: async (c, m) => void log.stored.push([c.id, m]),
    trackThread: async (c, channel, ts) => void log.tracked.push([c.id, channel, ts]),
    editMessage: async (_c, _ch, ts) => void log.edited.push(ts),
    markDeleted: async (_c, target) => void log.deleted.push({ ts: target.ts, createIfMissing: target.createIfMissing }),
    revokeConnections: async (teamId, users, before) => {
      log.revoked.push({ teamId, users, before });
      return users?.length ?? 2;
    },
    ...over,
  };
  return { deps, log };
}

const envelope = (event: Record<string, unknown>, over: Partial<SlackEventCallback> = {}): SlackEventCallback => ({
  type: "event_callback",
  team_id: "T1",
  event_id: "Ev1",
  event_time: Date.parse("2026-10-05T10:00:00Z") / 1000,
  event_context: "ctx",
  authorizations: [{ user_id: "U_A", team_id: "T1", is_bot: false }],
  event: { type: "message", ...event },
  ...over,
});

const dm = { channel: "D1", channel_type: "im", user: "U_X", text: "제안서는 월요일에 받아도 괜찮아요", ts: "1727678400.000100" };

describe("receiveSlackEvent", () => {
  it("DM을 이벤트가 이름을 댄 이용자의 대기 메시지로 넣는다", async () => {
    const { deps, log } = fakeDeps([ALICE]);
    const result = await receiveSlackEvent(envelope(dm), deps);
    expect(result).toMatchObject({ kept: 1, noConnection: false });
    expect(log.stored).toEqual([["conn-a", { channelId: "D1", channelType: "im", ts: "1727678400.000100", threadTs: null, senderId: "U_X", text: dm.text }]]);
    // 연결이 이 한 사람뿐이면 다른 이용자를 찾지 않는다
    expect(log.authorizationCalls).toBe(0);
  });

  it("같은 워크스페이스에 다른 연결이 있으면 이 이벤트를 볼 수 있는 이용자를 더 찾는다 (D4)", async () => {
    const { deps, log } = fakeDeps([ALICE, BOB]);
    await receiveSlackEvent(envelope(dm), deps);
    expect(log.authorizationCalls).toBe(1);
    expect(log.stored.map(([id]) => id).sort()).toEqual(["conn-a", "conn-b"]);

    const { deps: unknown, log: onlyAlice } = fakeDeps([ALICE, BOB], { authorizedUsers: async () => null });
    await receiveSlackEvent(envelope(dm), unknown);
    expect(onlyAlice.stored.map(([id]) => id)).toEqual(["conn-a"]);
  });

  it("연결이 없는 워크스페이스 · AI 처리에 동의하지 않은 이용자는 저장하지 않는다", async () => {
    const none = fakeDeps([]);
    expect(await receiveSlackEvent(envelope(dm), none.deps)).toMatchObject({ noConnection: true, kept: 0 });
    const { deps, log } = fakeDeps([ALICE], { consented: async () => false });
    expect(await receiveSlackEvent(envelope(dm), deps)).toMatchObject({ skippedNoConsent: 1, kept: 0 });
    expect(log.stored).toEqual([]);
  });

  it("채널에서 나와 무관한 글은 버리고, 추적 중인 스레드의 답글은 남기며 추적을 갱신한다", async () => {
    const channel = { channel: "C1", channel_type: "channel", user: "U_X", text: "참고로 금요일까지예요", ts: "1727678400.000200" };
    const plain = fakeDeps([ALICE]);
    expect(await receiveSlackEvent(envelope(channel), plain.deps)).toMatchObject({ kept: 0, dropped: 1 });
    expect(plain.log.stored).toEqual([]);

    const threaded = fakeDeps([ALICE], { isThreadTracked: async (_c, ch, ts) => ch === "C1" && ts === "1727678000.000001" });
    await receiveSlackEvent(envelope({ ...channel, thread_ts: "1727678000.000001" }), threaded.deps);
    expect(threaded.log.stored).toHaveLength(1);
    expect(threaded.log.tracked).toEqual([["conn-a", "C1", "1727678000.000001"]]);
  });

  it("고침을 넘기고, 지움은 표시로 남긴다 (DM은 행이 없어도 표시 행을 만들고 채널은 있는 행에만)", async () => {
    const { deps, log } = fakeDeps([ALICE]);
    await receiveSlackEvent(envelope({ channel: "D1", channel_type: "im", subtype: "message_changed", ts: "2.0", message: { ts: "1.0", text: "화요일로 바꿀게요" } }), deps);
    await receiveSlackEvent(envelope({ channel: "D1", channel_type: "im", subtype: "message_deleted", ts: "3.0", deleted_ts: "1.0" }), deps);
    await receiveSlackEvent(envelope({ channel: "C1", channel_type: "channel", subtype: "message_deleted", ts: "4.0", deleted_ts: "1.5" }), deps);
    expect(log.edited).toEqual(["1.0"]);
    expect(log.deleted).toEqual([
      { ts: "1.0", createIfMissing: true },
      { ts: "1.5", createIfMissing: false },
    ]);
  });

  it("다른 연결과 관계없을 채널 잡담에는 설치 조회(D4)를 하지 않는다 (3초 안에 답해야 한다)", async () => {
    const { deps, log } = fakeDeps([ALICE, BOB]);
    await receiveSlackEvent(envelope({ channel: "C1", channel_type: "channel", user: "U_X", text: "점심 뭐 먹을까요", ts: "5.0" }), deps);
    expect(log.authorizationCalls).toBe(0);
    await receiveSlackEvent(envelope({ channel: "C1", channel_type: "channel", user: "U_X", text: "<@U_B> 이거 봐주세요", ts: "6.0" }), deps);
    expect(log.authorizationCalls).toBe(1);
    expect(log.stored.map(([id]) => id)).toEqual(["conn-b"]);
  });

  it("app_uninstalled는 그 워크스페이스 전체, tokens_revoked는 해당 이용자만 이벤트 시각 기준으로 끊는다 (한 DB 함수)", async () => {
    const eventAt = new Date("2026-10-05T10:00:00Z");
    const uninstall = fakeDeps([]);
    expect(await receiveSlackEvent(envelope({ type: "app_uninstalled" }), uninstall.deps)).toMatchObject({ revoked: 2 });
    expect(uninstall.log.revoked).toEqual([{ teamId: "T1", users: null, before: eventAt }]);

    const tokens = fakeDeps([ALICE, BOB]);
    await receiveSlackEvent(envelope({ type: "tokens_revoked", tokens: { oauth: ["U_B"], bot: [] } }), tokens.deps);
    expect(tokens.log.revoked).toEqual([{ teamId: "T1", users: ["U_B"], before: eventAt }]);

    const botOnly = fakeDeps([ALICE]);
    await receiveSlackEvent(envelope({ type: "tokens_revoked", tokens: { bot: ["B1"] } }), botOnly.deps);
    expect(botOnly.log.revoked).toEqual([]);
  });

  it("모르는 이벤트 · 모양이 다른 메시지는 저장하지 않는다", async () => {
    const { deps, log } = fakeDeps([ALICE]);
    expect(await receiveSlackEvent(envelope({ type: "reaction_added" }), deps)).toMatchObject({ kept: 0, dropped: 0 });
    expect(await receiveSlackEvent(envelope({ channel: "D1" }), deps)).toMatchObject({ dropped: 1 });
    expect(log.stored).toEqual([]);
  });
});
