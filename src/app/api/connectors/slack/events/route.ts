import { receiveSlackEvent } from "@/lib/connectors/slack/receive";
import { slackReceiveDeps } from "@/lib/connectors/slack/store";
import { slackEnvelopeSchema } from "@/lib/connectors/slack/events";
import { verifySlackSignature } from "@/lib/connectors/slack/verify";
import { slackAppToken, slackSigningSecret } from "@/lib/env";
import { createAdminClient } from "@/lib/supabase/admin";

// Slack Events API가 메시지 · 앱 해제 이벤트를 보내는 곳 (Slack 앱 → Event Subscriptions → Request URL).
// 로그인 없이 부르므로 서명(X-Slack-Signature)으로만 Slack이 보낸 요청인지 확인한다 (docs/go-live/slack-integration.md 2-4).
// 3초 안에 답해야 한다: 남길 메시지를 대기 표에 넣기까지만 하고, 원문으로 묶는 일은 동기화가 한다.
// 저장에 실패하면 5xx로 답해 Slack이 다시 보내게 한다(같은 메시지는 한 행이라 중복되지 않는다).
// 받을 연결이 없거나 버린 이벤트도 200: 60분 동안 95% 넘게 실패하면 Slack이 구독을 끈다. 메시지 본문 · 이름 · id는 로그에 남기지 않는다.
export const maxDuration = 10;

/** Slack 이벤트 본문의 상한. 메시지 이벤트는 몇 KB라 넉넉하다 */
const MAX_BODY_BYTES = 1_000_000;

export async function POST(request: Request) {
  // 서명 헤더가 없거나 본문이 너무 크면 본문을 읽기 전에 거절한다
  const timestamp = request.headers.get("x-slack-request-timestamp");
  const signatureHeader = request.headers.get("x-slack-signature");
  if (!timestamp || !signatureHeader) return new Response(null, { status: 401 });
  if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY_BYTES) return new Response(null, { status: 413 });
  const body = await request.text();
  if (body.length > MAX_BODY_BYTES) return new Response(null, { status: 413 });

  let secret: string;
  try {
    secret = slackSigningSecret();
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    return new Response(null, { status: 500 });
  }
  const signature = verifySlackSignature({ secret, timestamp, signature: signatureHeader, body });
  if (signature !== "ok") return new Response(null, { status: 401 });

  let json: unknown;
  try {
    json = JSON.parse(body);
  } catch {
    return new Response(null, { status: 400 });
  }
  const envelope = slackEnvelopeSchema.safeParse(json);
  // 모르는 형식(다른 요청 종류)은 받고 버린다
  if (!envelope.success) return new Response(null, { status: 200 });
  if (envelope.data.type === "url_verification") return Response.json({ challenge: envelope.data.challenge });

  try {
    const result = await receiveSlackEvent(envelope.data, slackReceiveDeps(createAdminClient(), slackAppToken()));
    if (result.revoked > 0) console.log(`Slack 앱 해제: 연결 ${result.revoked}개를 끊었습니다.`);
    // 개발 서버에서만: 이벤트 종류와 처리 결과 개수 (본문 · 이름 · id 없음)
    if (process.env.NODE_ENV === "development") {
      const { type } = envelope.data.event;
      const subtype = typeof envelope.data.event.subtype === "string" ? `/${envelope.data.event.subtype}` : "";
      console.log(`Slack 이벤트 ${type}${subtype}: 남김 ${result.kept} · 버림 ${result.dropped} · 고침 ${result.edited} · 지움 ${result.deleted}${result.noConnection ? " · 연결 없음" : ""}`);
    }
    return new Response(null, { status: 200 });
  } catch (error) {
    console.error(`Slack 이벤트(${envelope.data.event.type}) 처리 실패:`, error instanceof Error ? error.message : error);
    return new Response(null, { status: 500 });
  }
}
