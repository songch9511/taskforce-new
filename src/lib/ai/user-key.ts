import "server-only";

import { createCipheriv, createDecipheriv, randomBytes, timingSafeEqual } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

// Lifetime 사용자의 OpenRouter 키 (BYOK, 결제 계약 6장): 봉인 · 열기 · 모양 검사 · 제공자에 검사 · 저장 표 읽기 · 쓰기.
// 키는 PUT 본문으로만 들어오고, 여기서 봉인한 글자만 DB(user_ai_keys)에 간다. 평문은 호출 한 번 동안 메모리에만 있다.
// 이 모듈의 오류 · 반환값 · 로그에 키(또는 일부)는 없다. 오류는 닫힌 코드 하나뿐이다.

const VERSION = "k1";
const KEY_VERSION = 1;
const IV_BYTES = 12;
const TAG_BYTES = 16;

export type UserKeyErrorCode = "user_key_config" | "user_key_open_failed" | "user_key_store_unavailable" | "byok_not_entitled";

/** message = code. 키 · 암호문 · env 값 · DB 오류 글은 담지 않는다 */
export class UserKeyError extends Error {
  constructor(readonly code: UserKeyErrorCode) {
    super(code);
    this.name = "UserKeyError";
  }
}

/**
 * USER_AI_KEY_ENCRYPTION_KEY: 32바이트를 base64로. CONNECTOR_TOKEN_KEY와 다른 값이어야 한다(한쪽이 새도 다른 쪽 비밀은 열리지 않게).
 * 회전 = 이 값을 바꾸고 사용자가 키를 다시 넣는다(키 하나, BL-21 A). key_version 열은 그때를 위해 둔다.
 */
export function userKeyEncryptionKey(env: Record<string, string | undefined> = process.env): Buffer {
  const raw = env.USER_AI_KEY_ENCRYPTION_KEY;
  const key = raw ? Buffer.from(raw, "base64") : Buffer.alloc(0);
  // 느슨한 base64 해석(깨진 글자를 건너뜀)이 32바이트처럼 보이는 것을 막는다: 다시 인코딩한 글자가 같아야 한다
  if (key.length !== 32 || key.toString("base64") !== raw) throw new UserKeyError("user_key_config");
  // 같은 바이트면 같은 키다: 글자 모양(패딩 · 공백 · base64url)이 달라도 걸린다. 커넥터 키는 connectors/crypto.ts parseTokenKey와 같은
  // 느슨한 base64 해석으로 푼다(실제로 그 키로 쓰이는 바이트와 견주려고). 32바이트가 아닌 값은 커넥터가 쓰지도 못하므로 견줄 것이 없다.
  const connector = env.CONNECTOR_TOKEN_KEY ? Buffer.from(env.CONNECTOR_TOKEN_KEY, "base64") : Buffer.alloc(0);
  if (connector.length === key.length && timingSafeEqual(connector, key)) throw new UserKeyError("user_key_config");
  return key;
}

/** AAD = openrouter:<user_id>. DB 쓰기 권한이 있는 사람이 B의 암호문을 A의 행에 옮겨도 열리지 않는다 */
const aad = (userId: string) => Buffer.from(`openrouter:${userId}`, "utf8");

export function sealUserKey(plaintext: string, userId: string, key: Buffer): string {
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv("aes-256-gcm", key, iv, { authTagLength: TAG_BYTES });
  cipher.setAAD(aad(userId));
  const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return [VERSION, iv.toString("base64"), cipher.getAuthTag().toString("base64"), encrypted.toString("base64")].join(".");
}

export function openUserKey(sealed: string, userId: string, key: Buffer): string {
  const parts = sealed.split(".");
  if (parts.length !== 4 || parts[0] !== VERSION) throw new UserKeyError("user_key_open_failed");
  try {
    const iv = Buffer.from(parts[1], "base64");
    const tag = Buffer.from(parts[2], "base64");
    if (iv.length !== IV_BYTES || tag.length !== TAG_BYTES || !parts[3]) throw new Error("shape");
    const decipher = createDecipheriv("aes-256-gcm", key, iv, { authTagLength: TAG_BYTES });
    decipher.setAAD(aad(userId));
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(Buffer.from(parts[3], "base64")), decipher.final()]).toString("utf8");
  } catch {
    // 원래 오류 글에는 암호문 조각이 있을 수 있다: 닫힌 코드만 남긴다
    throw new UserKeyError("user_key_open_failed");
  }
}

/** 보이는 ASCII만(공백 · 제어 문자 없음): 헤더에 넣을 때 깨지거나 오류 글에 값이 실리는 일을 막는다 */
const PRINTABLE = /^[\x21-\x7e]+$/;
export type KeyFormat = { ok: true; key: string } | { ok: false };

/** 길이 20–256 · 접두 sk-or-만 본다 (엄격한 정규식은 OpenRouter가 정하는 일이라 거기에 묻는다). 앞뒤 공백은 지운다 */
export function checkKeyFormat(raw: string): KeyFormat {
  const key = raw.trim();
  return key.length >= 20 && key.length <= 256 && key.startsWith("sk-or-") && PRINTABLE.test(key) ? { ok: true, key } : { ok: false };
}

const KEY_URL = "https://openrouter.ai/api/v1/key";
const VERIFY_TIMEOUT_MS = 10_000;
const keyInfoSchema = z.object({ data: z.object({ is_management_key: z.boolean().optional(), is_provisioning_key: z.boolean().optional() }).passthrough() });

export type KeyVerification = "ok" | "invalid" | "management" | "unavailable";

/**
 * GET /api/v1/key (비용 0, 10초): 200이고 관리 키가 아니면 ok, 401이면 invalid, 관리 키면 management.
 * 5xx · 시간 초과 · 모양이 다른 답 · 관리 키 표시(is_management_key · 옛 is_provisioning_key)가 없는 답 등 그 밖은 모두 unavailable — 확인하지 못한 키는 저장하지 않는다.
 * 고정 주소 하나에 이 키 하나만 헤더로 보낸다(리디렉션은 따르지 않는다). 본문(키를 되풀이할 수 있다)은 401에서 읽지 않는다.
 */
export async function verifyOpenRouterKey(key: string, send: typeof fetch = fetch): Promise<KeyVerification> {
  try {
    const response = await send(KEY_URL, { method: "GET", headers: { Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(VERIFY_TIMEOUT_MS), redirect: "error" });
    if (response.status === 401) return "invalid";
    if (response.status !== 200) return "unavailable";
    const info = keyInfoSchema.safeParse(await response.json());
    if (!info.success) return "unavailable";
    const { is_management_key: management, is_provisioning_key: provisioning } = info.data.data;
    // 닫힌 쪽: 관리 키인지 아닌지 어느 표시도 오지 않았다면 확인한 것이 아니다
    if (management === undefined && provisioning === undefined) return "unavailable";
    return management === true || provisioning === true ? "management" : "ok";
  } catch {
    return "unavailable";
  }
}

// ── 저장 표 (user_ai_keys, 서비스 역할만) ──

/** 성공 기록(last_ok_at)을 다시 쓰는 간격. 호출마다 쓰지 않는다 */
const OK_MARK_INTERVAL_MS = 3_600_000;

export type OwnKey =
  | { status: "missing" }
  | { status: "revoked" }
  /** 이 사용자의 것으로 열리지 않는 봉인 글자(env 키가 바뀜 · 행이 옮겨짐 · 모르는 판). 호출에는 쓰지 않는다 */
  | { status: "unreadable" }
  /** stale = 이 호출이 성공하면 성공 시각을 남기거나 한도 오류 표시를 거둬야 한다 */
  | { status: "connected"; key: string; sealed: string; stale: boolean };

/** 호출마다 DB에서 읽는다(캐시 없음): 사용자가 키를 바꾸거나 지운 것이 바로 반영되고, 다른 사용자의 키가 섞일 자리가 없다 */
export async function readUserKey(admin: SupabaseClient, userId: string, env: Record<string, string | undefined> = process.env): Promise<OwnKey> {
  const { data, error } = await admin.from("user_ai_keys").select("sealed_key,key_version,status,last_ok_at,last_spend_error_at").eq("user_id", userId).maybeSingle();
  if (error) throw new UserKeyError("user_key_store_unavailable");
  if (!data) return { status: "missing" };
  if (data.status === "revoked") return { status: "revoked" };
  if (data.status !== "connected" || data.key_version !== KEY_VERSION) return { status: "unreadable" };
  const encryptionKey = userKeyEncryptionKey(env);
  let key: string;
  try {
    key = openUserKey(data.sealed_key as string, userId, encryptionKey);
  } catch {
    return { status: "unreadable" };
  }
  const lastOk = data.last_ok_at ? Date.parse(data.last_ok_at as string) : Number.NaN;
  const stale = data.last_spend_error_at !== null || !Number.isFinite(lastOk) || Date.now() - lastOk > OK_MARK_INTERVAL_MS;
  return { status: "connected", key, sealed: data.sealed_key as string, stale };
}

export type KeyStatus = { ai_key: "connected" | "missing" | "revoked"; spend_error_at: string | null };

/** v2 상태의 ai_key. 암호문은 읽지 않는다 */
export async function userKeyStatus(admin: SupabaseClient, userId: string): Promise<KeyStatus> {
  const { data, error } = await admin.from("user_ai_keys").select("status,last_spend_error_at").eq("user_id", userId).maybeSingle();
  if (error) throw new UserKeyError("user_key_store_unavailable");
  if (!data) return { ai_key: "missing", spend_error_at: null };
  if (data.status === "revoked") return { ai_key: "revoked", spend_error_at: null };
  return { ai_key: "connected", spend_error_at: (data.last_spend_error_at as string | null) ?? null };
}

async function call(admin: SupabaseClient, name: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await admin.rpc(name, args);
  if (error) throw new UserKeyError(error.message.includes("byok_not_entitled") ? "byok_not_entitled" : "user_key_store_unavailable");
  return data;
}

/** 봉인해서 저장한다. 현재 Lifetime 권한이 있는 계정만 DB가 받는다. replaced = 이전 키를 바꿨는가 */
export async function putUserKey(admin: SupabaseClient, userId: string, key: string): Promise<{ replaced: boolean }> {
  const sealed = sealUserKey(key, userId, userKeyEncryptionKey());
  return { replaced: (await call(admin, "ai_key_put", { p_user_id: userId, p_sealed_key: sealed, p_key_version: KEY_VERSION })) === true };
}

export async function deleteUserKey(admin: SupabaseClient, userId: string): Promise<boolean> {
  return (await call(admin, "ai_key_delete", { p_user_id: userId })) === true;
}

/** 아래 셋은 호출이 쓴 바로 그 봉인 글자일 때만 행을 건드린다(그 사이 키를 바꿨으면 새 키는 그대로) */
export async function markUserKeyRevoked(admin: SupabaseClient, userId: string, sealed: string): Promise<void> {
  await call(admin, "ai_key_mark_revoked", { p_user_id: userId, p_sealed_key: sealed });
}

export async function noteUserKeySpendError(admin: SupabaseClient, userId: string, sealed: string): Promise<void> {
  await call(admin, "ai_key_note_spend_error", { p_user_id: userId, p_sealed_key: sealed });
}

export async function noteUserKeyOk(admin: SupabaseClient, userId: string, sealed: string): Promise<void> {
  await call(admin, "ai_key_note_ok", { p_user_id: userId, p_sealed_key: sealed });
}

/** 키 저장 · 검사 속도 제한: 사용자별 시간당 10회 (kind ai_key, 20261130000000) */
export const AI_KEY_LIMIT = { max: 10, windowMs: 3_600_000 } as const;
