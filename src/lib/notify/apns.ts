import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { connect } from "node:http2";

// Apple Push Notification service (토큰 방식, .p8 키). iOS · macOS 앱이 같은 번들 ID를 쓴다.
// 키가 설정되지 않았으면 알림은 꺼진 채로 동작한다 (apnsConfigFromEnv → null).

export type ApnsConfig = { keyId: string; teamId: string; key: KeyObject; bundleId: string };
export type ApnsDevice = { token: string; environment: "sandbox" | "production" };
export type ApnsPayload = {
  aps: { alert: { title: string; body: string }; sound?: string; "thread-id"?: string; "mutable-content"?: 1 };
  [key: string]: unknown;
};

export function apnsConfigFromEnv(env: Record<string, string | undefined> = process.env): ApnsConfig | null {
  const { APNS_KEY_ID: keyId, APNS_TEAM_ID: teamId, APNS_PRIVATE_KEY: pem } = env;
  if (!keyId || !teamId || !pem) return null;
  return {
    keyId,
    teamId,
    // .env에는 줄바꿈을 \n으로 적는다
    key: createPrivateKey(pem.replace(/\\n/g, "\n")),
    bundleId: env.APNS_BUNDLE_ID || "dev.taskforcelabs.taskforce",
  };
}

const base64url = (input: Buffer | string) => Buffer.from(input).toString("base64url");

/** 공급자 인증 토큰 (ES256 JWT). Apple은 20분~1시간마다 새로 만들라고 한다. */
export function providerToken(config: Pick<ApnsConfig, "keyId" | "teamId" | "key">, now = new Date()): string {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: config.keyId }));
  const claims = base64url(JSON.stringify({ iss: config.teamId, iat: Math.floor(now.getTime() / 1000) }));
  const signature = sign("sha256", Buffer.from(`${header}.${claims}`), { key: config.key, dsaEncoding: "ieee-p1363" });
  return `${header}.${claims}.${base64url(signature)}`;
}

let cached: { token: string; at: number; keyId: string } | null = null;
function cachedToken(config: ApnsConfig): string {
  if (!cached || cached.keyId !== config.keyId || Date.now() - cached.at > 40 * 60_000) {
    cached = { token: providerToken(config), at: Date.now(), keyId: config.keyId };
  }
  return cached.token;
}

export type PushResult = { ok: true } | { ok: false; status: number; reason: string | null; unregistered: boolean };

export type Transport = (request: { host: string; path: string; headers: Record<string, string>; body: string }) => Promise<{ status: number; body: string }>;

export const http2Transport: Transport = ({ host, path, headers, body }) =>
  new Promise((resolve, reject) => {
    const client = connect(`https://${host}`);
    client.on("error", reject);
    const req = client.request({ ":method": "POST", ":path": path, ...headers });
    // 멈춘 연결이 원문 처리 · cron을 붙잡지 않게 한다.
    req.setTimeout(10_000, () => {
      req.close();
      client.close();
      reject(new Error("APNs 응답 시간 초과"));
    });
    let status = 0;
    let data = "";
    req.setEncoding("utf8");
    req.on("response", (h) => (status = Number(h[":status"])));
    req.on("data", (chunk) => (data += chunk));
    req.on("end", () => {
      client.close();
      resolve({ status, body: data });
    });
    req.on("error", (error) => {
      client.close();
      reject(error);
    });
    req.end(body);
  });

export async function sendPush(config: ApnsConfig, device: ApnsDevice, payload: ApnsPayload, transport: Transport = http2Transport): Promise<PushResult> {
  const host = device.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const response = await transport({
    host,
    path: `/3/device/${device.token}`,
    headers: {
      authorization: `bearer ${cachedToken(config)}`,
      "apns-topic": config.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (response.status === 200) return { ok: true };
  const reason = (() => {
    try {
      return (JSON.parse(response.body) as { reason?: string }).reason ?? null;
    } catch {
      return null;
    }
  })();
  // 410 Unregistered · 400 BadDeviceToken: 이 토큰은 더 쓰지 않는다
  return { ok: false, status: response.status, reason, unregistered: response.status === 410 || reason === "BadDeviceToken" };
}

// ─── 알림 내용 ───────────────────────────────────────────
// 할 일 제목(회의록 · 메시지에서 나온 내용)은 잠금 화면에 싣지 않는다. mutable-content로 보내
// 앱의 알림 확장(Notification Service Extension)이 로그인 세션으로 제목을 받아와 채운다.

export function confirmationPayload(action: { id: string }): ApnsPayload {
  return {
    aps: { alert: { title: "확인이 필요해요", body: "새로 찾은 할 일을 확인해 주세요" }, sound: "default", "thread-id": "confirmations", "mutable-content": 1 },
    action_id: action.id,
    kind: "confirmation",
  };
}

export function duePayload(actions: { id: string; due_date: string }[], today: string): ApnsPayload {
  const dueToday = actions.filter((a) => a.due_date <= today);
  const first = dueToday[0] ?? actions[0];
  const title = dueToday.length > 0 ? `오늘까지 ${dueToday.length}건` : `내일까지 ${actions.length}건`;
  return {
    aps: { alert: { title, body: "지금 할 일을 확인해 주세요" }, sound: "default", "thread-id": "due", "mutable-content": 1 },
    action_id: first.id,
    action_ids: actions.slice(0, 20).map((a) => a.id),
    kind: "due",
  };
}
