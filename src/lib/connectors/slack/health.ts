// Slack 토큰 확인 (매일, /api/cron/retention). 이용자가 Slack에서 앱을 지우거나 권한을 거두면 Slack이 app_uninstalled ·
// tokens_revoked 이벤트를 보내고 그때 연결을 끊어 Slack 글자를 지운다(D3). 그 이벤트를 놓치면(서버 장애 · 재시도 소진) 대기 메시지가
// 없는 한 동기화는 Slack을 부르지 않아 알아챌 길이 없다. 그래서 하루에 한 번 토큰이 살아 있는지 묻고, 죽었으면 앱 해제와 같게 처리한다
// (Slack 개발자 정책: 앱을 지우면 14 영업일 안에 관련 데이터를 모두 지운다. docs/go-live/slack-integration.md D3).

export type SlackTokenCheckTarget = { id: string; teamId: string; slackUserId: string };

export type SlackHealthDeps = {
  /** 끊기지 않은(active · error) Slack 연결 */
  connections: () => Promise<SlackTokenCheckTarget[]>;
  /** 토큰이 살아 있으면 true, Slack이 토큰을 쓸 수 없다고 하면 false. 그 밖의 실패(장애 · 토큰을 풀지 못함)는 던진다 */
  tokenAlive: (connection: SlackTokenCheckTarget) => Promise<boolean>;
  /** 앱 해제와 같은 처리 (revoke_slack_connections: 토큰 삭제 · D3 · revoked). 끊은 연결 수 */
  revoke: (connection: SlackTokenCheckTarget) => Promise<number>;
};

export type SlackTokenCheckResult = { checked: number; revoked: number; failed: number };

export async function checkSlackTokens(deps: SlackHealthDeps, options: { deadline?: number } = {}): Promise<SlackTokenCheckResult> {
  const result: SlackTokenCheckResult = { checked: 0, revoked: 0, failed: 0 };
  for (const connection of await deps.connections()) {
    if (options.deadline && Date.now() > options.deadline) break;
    try {
      result.checked++;
      if (!(await deps.tokenAlive(connection))) result.revoked += await deps.revoke(connection);
    } catch (error) {
      // 하나가 실패해도 나머지는 확인한다. 다음 날 다시 본다
      result.failed++;
      console.error(`Slack 토큰 확인 실패 (${connection.id}):`, error instanceof Error ? error.message : error);
    }
  }
  return result;
}
