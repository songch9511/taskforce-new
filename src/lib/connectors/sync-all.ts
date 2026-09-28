import type { Connection, ConnectorSyncOutcome } from "./types";

// 여러 연결을 차례로 동기화하는 규칙 (순수 함수: DB · 연동 호출은 인자로 받는다). registry.ts의 syncConnections가 쓴다.
// - 외부 AI 처리에 동의하지 않은 사용자의 연결은 건너뛴다 (원문을 가져오지도 처리하지도 않는다. 커서도 그대로라 동의하면 이어서 가져온다)
//   대상 연결은 이미 동의한 사용자 것만 고르지만(syncable_connections), 연결마다 시작 직전에 다시 확인해 도중의 철회도 따른다.
// - 수동 동기화는 연결마다 minIntervalMs 안에 다시 돌리지 않는다
// - 실행 시간 한도(deadline)를 넘기면 남은 연결은 다음 차례로 미룬다

export type SyncAllDeps = {
  /** 동기화할 연결 (동의한 사용자 것만, 오래 안 한 순서) */
  connections: () => Promise<Connection[]>;
  /** 지금 외부 AI 처리에 동의한 상태인가 (연결마다 시작 직전에 다시 읽는다) */
  consented: (userId: string) => Promise<boolean>;
  sync: (connection: Connection) => Promise<ConnectorSyncOutcome>;
  now?: () => number;
};

export type SyncAllResult = {
  outcomes: ConnectorSyncOutcome[];
  /** 외부 AI 처리 동의가 없어(도중에 철회) 건너뛴 연결 수 */
  withoutConsent: number;
};

export async function syncEach(deps: SyncAllDeps, options: { deadline?: number; minIntervalMs?: number } = {}): Promise<SyncAllResult> {
  const now = deps.now ?? Date.now;
  const connections = await deps.connections();

  const outcomes: ConnectorSyncOutcome[] = [];
  let withoutConsent = 0;
  for (const connection of connections) {
    // 수동 동기화를 연달아 누르지 못하게 한다.
    const since = connection.lastSyncedAt ? now() - connection.lastSyncedAt.getTime() : Infinity;
    if (options.minIntervalMs && since < options.minIntervalMs) {
      outcomes.push({ connectionId: connection.id, ok: false, error: "방금 동기화했습니다. 잠시 뒤 다시 시도해 주세요.", revoked: false, busy: true });
      continue;
    }
    if (options.deadline && now() > options.deadline) break;
    if (!(await deps.consented(connection.userId))) {
      withoutConsent++;
      continue;
    }
    outcomes.push(await deps.sync(connection));
  }
  return { outcomes, withoutConsent };
}
