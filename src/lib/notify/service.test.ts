import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { apnsConfigFromEnv, sendPush, type ApnsConfig } from "./apns";
import { notifyReconnect } from "./service";

vi.mock("server-only", () => ({}));
vi.mock("./apns", async (importOriginal) => ({ ...(await importOriginal<typeof import("./apns")>()), apnsConfigFromEnv: vi.fn(), sendPush: vi.fn() }));

// 재연결 알림 (docs/go-live/google-integration.md G9): 기기로 한 번 보내고, 실제로 보냈으면 지표 이벤트를 남긴다.

const config = {} as ApnsConfig;
const device = { id: "d1", user_id: "u1", token: "a".repeat(64), environment: "sandbox" as const };

/** devices 조회 · 삭제와 metric_events 삽입을 기록하는 가짜 service role 클라이언트 */
function fakeAdmin(devices: (typeof device)[]) {
  const inserted: { table: string; row: unknown }[] = [];
  const deleted: string[] = [];
  const admin = {
    from: (table: string) => ({
      select: () => ({ in: () => ({ throwOnError: async () => ({ data: devices }) }) }),
      delete: () => ({ eq: (_column: string, id: string) => ({ eq: async () => void deleted.push(id) }) }),
      insert: (row: unknown) => ({
        throwOnError: async () => {
          inserted.push({ table, row });
        },
      }),
    }),
  } as unknown as SupabaseClient;
  return { admin, inserted, deleted };
}

beforeEach(() => {
  vi.resetAllMocks();
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.mocked(apnsConfigFromEnv).mockReturnValue(config);
  vi.mocked(sendPush).mockResolvedValue({ ok: true });
});

describe("notifyReconnect", () => {
  it("서비스 이름이 든 문구와 kind reconnect만 보내고(할 일 정보 없음), 보낸 기록을 지표 이벤트로 남긴다", async () => {
    const { admin, inserted } = fakeAdmin([device]);

    expect(await notifyReconnect(admin, "u1", "gmail")).toBe(1);

    expect(sendPush).toHaveBeenCalledTimes(1);
    const payload = vi.mocked(sendPush).mock.calls[0][2];
    expect(payload).toEqual({
      aps: { alert: { title: "Connections", body: "Reconnect Gmail to keep syncing." }, sound: "default", "thread-id": "connections" },
      kind: "reconnect",
    });
    expect(inserted).toEqual([{ table: "metric_events", row: { user_id: "u1", type: "reconnect_notified" } }]);
  });

  it("Notion도 같은 문구에 서비스 이름만 바뀐다", async () => {
    const { admin } = fakeAdmin([device]);
    await notifyReconnect(admin, "u1", "notion");
    expect(vi.mocked(sendPush).mock.calls[0][2].aps.alert.body).toBe("Reconnect Notion to keep syncing.");
  });

  it("기기가 여럿이어도 알림은 기기마다 하나, 이벤트는 한 줄", async () => {
    const { admin, inserted } = fakeAdmin([device, { ...device, id: "d2", token: "b".repeat(64) }]);
    expect(await notifyReconnect(admin, "u1", "gmail")).toBe(2);
    expect(sendPush).toHaveBeenCalledTimes(2);
    expect(inserted).toHaveLength(1);
  });

  it("APNs 키가 없으면 아무것도 하지 않는다", async () => {
    vi.mocked(apnsConfigFromEnv).mockReturnValue(null);
    const { admin, inserted } = fakeAdmin([device]);
    expect(await notifyReconnect(admin, "u1", "gmail")).toBe(0);
    expect(sendPush).not.toHaveBeenCalled();
    expect(inserted).toEqual([]);
  });

  it("등록된 기기가 없으면 보내지도 이벤트를 남기지도 않는다", async () => {
    const { admin, inserted } = fakeAdmin([]);
    expect(await notifyReconnect(admin, "u1", "gmail")).toBe(0);
    expect(sendPush).not.toHaveBeenCalled();
    expect(inserted).toEqual([]);
  });

  it("보내지 못했으면(APNs 거절 · 등록 해제된 기기) 이벤트를 남기지 않고, 해제된 기기는 지운다", async () => {
    vi.mocked(sendPush).mockResolvedValue({ ok: false, status: 410, reason: "Unregistered", unregistered: true });
    const { admin, inserted, deleted } = fakeAdmin([device]);
    expect(await notifyReconnect(admin, "u1", "gmail")).toBe(0);
    expect(deleted).toEqual(["d1"]);
    expect(inserted).toEqual([]);
  });
});
