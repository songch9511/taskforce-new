import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { apnsConfigFromEnv, confirmationPayload, duePayload, sendPush, type ApnsConfig, type ApnsPayload } from "./apns";

// 누가 어떤 알림을 받을지 정하고 보낸다. APNs 키가 없으면 아무것도 하지 않는다 (Phase A3에서 키 발급).

type DeviceRow = { id: string; user_id: string; token: string; environment: "sandbox" | "production" };

async function pushToUser(admin: SupabaseClient, config: ApnsConfig, devices: DeviceRow[], payload: ApnsPayload): Promise<number> {
  let sent = 0;
  for (const device of devices) {
    try {
      const result = await sendPush(config, device, payload);
      if (result.ok) sent++;
      else if (result.unregistered) await admin.from("devices").delete().eq("id", device.id).eq("user_id", device.user_id);
      else console.error(`알림 실패 (${device.id}): ${result.status} ${result.reason ?? ""}`);
    } catch (error) {
      console.error(`알림 실패 (${device.id}):`, error instanceof Error ? error.message : error);
    }
  }
  return sent;
}

/** 사용자가 많아도 요청 주소가 길어지지 않게 100명씩 나눠 읽는다. */
async function devicesOf(admin: SupabaseClient, userIds: string[]): Promise<DeviceRow[]> {
  const rows: DeviceRow[] = [];
  for (let i = 0; i < userIds.length; i += 100) {
    const { data } = await admin.from("devices").select("id, user_id, token, environment").in("user_id", userIds.slice(i, i + 100)).throwOnError();
    rows.push(...((data ?? []) as DeviceRow[]));
  }
  return rows;
}

/** 원문 처리로 확인 요청이 새로 생겼을 때 */
export async function notifyConfirmations(admin: SupabaseClient, userId: string, actionIds: string[]): Promise<number> {
  const config = apnsConfigFromEnv();
  if (!config || actionIds.length === 0) return 0;
  const devices = await devicesOf(admin, [userId]);
  if (devices.length === 0) return 0;

  // 한 원문에서 확인 요청이 여럿 생겨도 알림은 하나 (가장 먼저 생긴 것으로 연다)
  return pushToUser(admin, config, devices, confirmationPayload({ id: actionIds[0] }));
}

const kstDate = (date: Date) => new Date(date.getTime() + 9 * 3_600_000).toISOString().slice(0, 10);

/** 아침 알림: 오늘 · 내일 마감인 열린 내 일 (사용자마다 한 번) */
export async function notifyDueSoon(admin: SupabaseClient, now = new Date()): Promise<{ users: number; sent: number }> {
  const config = apnsConfigFromEnv();
  if (!config) return { users: 0, sent: 0 };
  const today = kstDate(now);
  const tomorrow = kstDate(new Date(now.getTime() + 86_400_000));

  // 한 번에 1000건씩 끝까지 읽는다 (PostgREST 최대 행 수에 잘리지 않게).
  const byUser = new Map<string, { id: string; due_date: string }[]>();
  for (let from = 0; ; from += 1000) {
    const { data } = await admin
      .from("actions")
      .select("id, user_id, due_date")
      .eq("status", "open")
      .eq("owner", "me")
      .eq("needs_confirmation", false)
      .lte("due_date", tomorrow)
      .order("id")
      .range(from, from + 999)
      .throwOnError();
    const rows = (data ?? []) as { id: string; user_id: string; due_date: string }[];
    for (const row of rows) byUser.set(row.user_id, [...(byUser.get(row.user_id) ?? []), row]);
    if (rows.length < 1000) break;
  }
  for (const list of byUser.values()) list.sort((a, b) => a.due_date.localeCompare(b.due_date));

  const devices = await devicesOf(admin, [...byUser.keys()]);
  let sent = 0;
  for (const [userId, actions] of byUser) {
    const mine = devices.filter((d) => d.user_id === userId);
    if (mine.length > 0) sent += await pushToUser(admin, config, mine, duePayload(actions, today));
  }
  return { users: byUser.size, sent };
}
