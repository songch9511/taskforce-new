import { cronAuthorized, cronUnauthorized } from "@/lib/api/cron";
import { checkSlackConnectionTokens } from "@/lib/connectors/slack/run";
import { retentionCutoff, SLACK_PENDING_RETENTION_DAYS, SLACK_THREAD_RETENTION_DAYS } from "@/lib/retention";
import { createAdminClient } from "@/lib/supabase/admin";

// 원문 보관 기간 정리 (Vercel Cron, 매일). Authorization: Bearer $CRON_SECRET 인 요청만 받는다.
// 90일이 지난 원문의 글 · 판정 기록, 하루 지난 시도 기록(rate_limit_events · missing_reports)을 지운다 (src/lib/retention.ts).
// Slack 대기 메시지(받은 지 3일) · 추적 스레드(마지막 활동 뒤 14일)도 지우고, 연결을 끊어 지운 원문에 남은 글자가 있으면 다시 지운다 (purge_slack_buffers).
// 끝으로 Slack 토큰이 살아 있는지 확인한다: Slack에서 앱을 지웠다는 이벤트를 놓쳤어도 하루 안에 끊고 Slack 글자를 지운다 (slack/health.ts).
// 실행 산출물(내장 초안)은 보관 기간(retain_until, 열 기본값)이 지난 본문만 맨 먼저 비운다 (purge_expired_artifacts, 한도 없는 한 문장.
// 운영자 시험 규모라 짧다. 밀린 산출물이 많아지면 그만큼 원문 정리 시간이 줄어든다: 그때 한도를 두는 판으로 바꾼다).
// 실패해도 나머지 정리 · Slack 토큰 확인은 하고, 응답을 500으로 해 cron 기록에 남긴다.
// 한 번에 최대 PURGE_LIMIT건씩 지우므로, 밀린 게 있으면(어느 하나라도 한도만큼 지워졌으면) 시간 한도 안에서 반복해서 부른다.
export const maxDuration = 60;

const PURGE_LIMIT = 5000;
// maxDuration보다 조금 일찍 멈추고 남은 것은 다음 날 마저 지운다 (응답을 만들 시간을 남긴다).
const TIME_BUDGET_MS = (maxDuration - 10) * 1000;
// 그중 Slack 토큰 확인에 떼어 두는 시간: 정리가 밀린 날에도 토큰 확인은 돈다 (앱 해제 이벤트를 놓쳤을 때의 안전망, D3)
const SLACK_TOKEN_CHECK_MS = 20_000;
// 한도 직전에 시작한 Slack 호출이 끝날 시간 (slack/client.ts 호출 제한 10초)
const SLACK_CALL_TIMEOUT_MS = 10_000;

type PurgeCounts = { sources_purged: number; judge_logs_deleted: number; rate_limit_events_deleted: number; missing_reports_deleted: number };
type SlackPurgeCounts = { messages_deleted: number; threads_deleted: number; sources_repurged: number };

export async function GET(request: Request) {
  if (!cronAuthorized(request)) return cronUnauthorized();

  const admin = createAdminClient();
  const now = new Date();
  const before = retentionCutoff(now).toISOString();
  const totals: PurgeCounts = { sources_purged: 0, judge_logs_deleted: 0, rate_limit_events_deleted: 0, missing_reports_deleted: 0 };
  const started = Date.now();
  const tokenDeadline = started + TIME_BUDGET_MS - SLACK_CALL_TIMEOUT_MS;
  const purgeDeadline = tokenDeadline - SLACK_TOKEN_CHECK_MS;
  let calls = 1; // purge_expired_artifacts
  const artifactsPurged = await admin
    .rpc("purge_expired_artifacts")
    .throwOnError()
    .then(
      ({ data }) => data as number,
      (error: unknown) => {
        console.error("실행 산출물 본문 정리 실패:", error instanceof Error ? error.message : error);
        return null;
      },
    );
  for (;;) {
    calls++;
    const { data } = await admin
      .rpc("purge_expired_source_text", { p_before: before, p_limit: PURGE_LIMIT })
      .single<PurgeCounts>()
      .throwOnError();
    for (const key of Object.keys(totals) as (keyof PurgeCounts)[]) totals[key] += data[key];
    const moreLeft = Object.values(data).some((n) => n >= PURGE_LIMIT);
    if (!moreLeft || Date.now() > purgeDeadline) break;
  }

  const slack: SlackPurgeCounts = { messages_deleted: 0, threads_deleted: 0, sources_repurged: 0 };
  for (;;) {
    calls++;
    const { data } = await admin
      .rpc("purge_slack_buffers", {
        p_messages_before: retentionCutoff(now, SLACK_PENDING_RETENTION_DAYS).toISOString(),
        p_threads_before: retentionCutoff(now, SLACK_THREAD_RETENTION_DAYS).toISOString(),
        p_limit: PURGE_LIMIT,
      })
      .single<SlackPurgeCounts>()
      .throwOnError();
    slack.messages_deleted += data.messages_deleted;
    slack.threads_deleted += data.threads_deleted;
    slack.sources_repurged += data.sources_repurged;
    const moreLeft = Object.values(data).some((n) => n >= PURGE_LIMIT);
    if (!moreLeft || Date.now() > purgeDeadline) break;
  }
  const slackTokens = await checkSlackConnectionTokens(admin, { now, deadline: tokenDeadline }).catch((error) => {
    console.error("Slack 토큰 확인 실패:", error instanceof Error ? error.message : error);
    return null;
  });
  return Response.json(
    {
      ...totals,
      artifacts_purged: artifactsPurged,
      slack_tokens_checked: slackTokens?.checked ?? 0,
      slack_tokens_revoked: slackTokens?.revoked ?? 0,
      slack_messages_deleted: slack.messages_deleted,
      slack_threads_deleted: slack.threads_deleted,
      slack_sources_repurged: slack.sources_repurged,
      calls,
    },
    { status: artifactsPurged === null ? 500 : 200 },
  );
}
