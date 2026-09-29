import { generateKeyPairSync, verify } from "node:crypto";

import { describe, expect, it } from "vitest";

import { apnsConfigFromEnv, confirmationPayload, duePayload, providerToken, sendPush, type ApnsConfig, type Transport } from "./apns";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const config: ApnsConfig = { keyId: "ABC123DEFG", teamId: "U9DWQKQFMW", key: privateKey, bundleId: "dev.taskforcelabs.taskforce" };

describe("providerToken", () => {
  it("ES256으로 서명한 JWT (kid · iss · iat)", () => {
    const token = providerToken(config, new Date("2026-09-26T00:00:00Z"));
    const [header, claims, signature] = token.split(".");
    expect(JSON.parse(Buffer.from(header, "base64url").toString())).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(JSON.parse(Buffer.from(claims, "base64url").toString())).toEqual({ iss: "U9DWQKQFMW", iat: 1790380800 });
    const ok = verify("sha256", Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url"));
    expect(ok).toBe(true);
  });
});

describe("apnsConfigFromEnv", () => {
  it("키가 없으면 알림을 끈다", () => {
    expect(apnsConfigFromEnv({})).toBeNull();
  });

  it(".env의 \\n을 줄바꿈으로 바꿔 키를 읽는다", () => {
    const pem = (privateKey.export({ type: "pkcs8", format: "pem" }) as string).replace(/\n/g, "\\n");
    const c = apnsConfigFromEnv({ APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_PRIVATE_KEY: pem });
    expect(c).toMatchObject({ keyId: "k", teamId: "t", bundleId: "dev.taskforcelabs.taskforce" });
  });
});

describe("sendPush", () => {
  const device = { token: "a".repeat(64), environment: "sandbox" as const };

  it("기기 환경에 맞는 서버로 헤더와 함께 보낸다", async () => {
    const sent: Parameters<Transport>[0][] = [];
    const transport: Transport = async (request) => {
      sent.push(request);
      return { status: 200, body: "" };
    };
    expect(await sendPush(config, device, confirmationPayload({ id: "a1" }), transport)).toEqual({ ok: true });
    expect(sent[0]).toMatchObject({
      host: "api.sandbox.push.apple.com",
      path: `/3/device/${device.token}`,
      headers: { "apns-topic": "dev.taskforcelabs.taskforce", "apns-push-type": "alert" },
    });
    expect(sent[0].headers.authorization).toMatch(/^bearer ey/);
    const body = JSON.parse(sent[0].body);
    expect(body).toMatchObject({ aps: { alert: { title: "Review", body: "New tasks to confirm" }, "mutable-content": 1 }, action_id: "a1" });
  });

  it("만료된 토큰(410)은 지울 대상으로 알려준다", async () => {
    const transport: Transport = async () => ({ status: 410, body: JSON.stringify({ reason: "Unregistered" }) });
    expect(await sendPush(config, device, confirmationPayload({ id: "a1" }), transport)).toEqual({
      ok: false,
      status: 410,
      reason: "Unregistered",
      unregistered: true,
    });
  });
});

describe("duePayload", () => {
  it("오늘 마감 건수와 id만 보낸다", () => {
    const p = duePayload(
      [
        { id: "a1", due_date: "2026-09-26" },
        { id: "a2", due_date: "2026-09-27" },
      ],
      "2026-09-26",
    );
    expect(p.aps.alert).toEqual({ title: "Due today", body: "1 task" });
    expect(p).toMatchObject({ action_id: "a1", action_ids: ["a1", "a2"] });
  });

  it("오늘 마감이 없으면 내일 마감 건수를 보낸다 (앱 문구와 같은 영어)", () => {
    const p = duePayload(
      [
        { id: "a1", due_date: "2026-09-27" },
        { id: "a2", due_date: "2026-09-27" },
      ],
      "2026-09-26",
    );
    expect(p.aps.alert).toEqual({ title: "Due tomorrow", body: "2 tasks" });
  });
});
