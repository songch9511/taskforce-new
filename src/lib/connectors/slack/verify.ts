import { createHmac, timingSafeEqual } from "node:crypto";

// Slack 요청 서명 확인 (https://docs.slack.dev/authentication/verifying-requests-from-slack):
// X-Slack-Signature = "v0=" + HMAC-SHA256(서명 키, "v0:{X-Slack-Request-Timestamp}:{본문 그대로}").
// 5분보다 오래된 요청은 다시 보낸 공격일 수 있어 거절한다. 본문은 JSON으로 풀기 전의 문자열이어야 한다.

export const SLACK_SIGNATURE_MAX_AGE_SECONDS = 300;

export type SignatureCheck = "ok" | "stale" | "invalid";

export function verifySlackSignature(input: {
  secret: string;
  timestamp: string | null;
  signature: string | null;
  body: string;
  now?: Date;
}): SignatureCheck {
  const { secret, timestamp, signature, body } = input;
  if (!timestamp || !signature || !/^\d+$/.test(timestamp)) return "invalid";
  const nowSeconds = (input.now ?? new Date()).getTime() / 1000;
  if (Math.abs(nowSeconds - Number(timestamp)) > SLACK_SIGNATURE_MAX_AGE_SECONDS) return "stale";
  const expected = Buffer.from(`v0=${createHmac("sha256", secret).update(`v0:${timestamp}:${body}`).digest("hex")}`);
  const given = Buffer.from(signature);
  return expected.length === given.length && timingSafeEqual(expected, given) ? "ok" : "invalid";
}
