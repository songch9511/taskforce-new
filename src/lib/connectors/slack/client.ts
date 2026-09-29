import { z } from "zod";

// Slack Web API 호출. 응답은 모두 zod로 확인한다. 토큰은 로그에 남기지 않는다.

const SLACK_API = "https://slack.com/api";

const authorizationsSchema = z.object({
  ok: z.boolean(),
  error: z.string().optional(),
  authorizations: z.array(z.object({ user_id: z.string().optional(), team_id: z.string().optional(), is_bot: z.boolean().optional() })).optional(),
  response_metadata: z.object({ next_cursor: z.string().optional() }).optional(),
});

/**
 * 이 이벤트를 볼 수 있는 설치(이용자)의 Slack 사용자 id 모두 (apps.event.authorizations.list, 앱 수준 토큰 · authorizations:read).
 * Slack은 같은 메시지를 워크스페이스에 한 번만, 설치 하나의 이름으로 보낸다. 같은 워크스페이스에 Taskforce 이용자가 둘 이상이면
 * 나머지 이용자를 여기서 찾는다(slack-integration.md D4). 이벤트에 3초 안에 답해야 해서 짧게 기다린다.
 */
export async function eventAuthorizedUsers(
  appToken: string,
  eventContext: string,
  fetchImpl: typeof fetch = fetch,
  options: { timeoutMs?: number; maxPages?: number } = {},
): Promise<string[]> {
  const users = new Set<string>();
  let cursor = "";
  for (let page = 0; page < (options.maxPages ?? 5); page++) {
    const response = await fetchImpl(`${SLACK_API}/apps.event.authorizations.list`, {
      method: "POST",
      headers: { Authorization: `Bearer ${appToken}`, "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ event_context: eventContext, ...(cursor ? { cursor } : {}) }),
      signal: AbortSignal.timeout(options.timeoutMs ?? 1500),
    });
    const body = authorizationsSchema.parse(await response.json());
    if (!body.ok) throw new Error(`Slack apps.event.authorizations.list 실패: ${body.error ?? response.status}`);
    for (const authorization of body.authorizations ?? []) {
      if (authorization.user_id && !authorization.is_bot) users.add(authorization.user_id);
    }
    cursor = body.response_metadata?.next_cursor ?? "";
    if (!cursor) break;
  }
  return [...users];
}
