import type { SupabaseClient } from "@supabase/supabase-js";

import type { ConnectedStatusValue, ConnectProvider, ParticipantsInput } from "@/lib/api/contract";
import type { SourceKind } from "@/lib/pipeline/extract";

// 모든 연동(Notion · Google · Gmail · Slack · GitHub)이 만들어 내는 공통 형태.
// 연동 모듈은 외부 항목을 이 형태로 바꾸기만 하고, 저장 · 추출은 ingest.ts가 한다.

export type Provider = "notion" | "google" | "gmail" | "slack" | "github";

/** 회의 원문(Notion 회의록 · Meet 전사)에 붙인 Calendar 일정 (sources.meeting). 일정의 제목 · 시각만 남긴다 (google-integration.md 2-7) */
export type SourceMeeting = { calendar_event_id: string; title: string | null; start: string; end: string };

export type IngestItem = {
  /** 외부 서비스의 항목 id (예: Notion 페이지 id) */
  externalId: string;
  /** 같은 항목이 바뀌었는지 가르는 값 (예: last_edited_time) */
  externalVersion: string;
  kind: SourceKind;
  title: string | null;
  text: string;
  occurredAt: Date;
  /** 외부 서비스에서 마지막으로 고친 시각. 막 고쳐진 항목은 안정될 때까지 기다린다 */
  lastEditedAt: Date;
  externalUrl: string | null;
  participants?: ParticipantsInput;
  /** 사용자가 직접 쓴 원문인가 (sources.written_by_me). 모르면 null · 없음 */
  writtenByMe?: boolean | null;
  /** 같은 회의의 Calendar 일정 (없으면 없음). 앱이 근거 줄의 출처 · Sources 묶기에 쓴다 */
  meeting?: SourceMeeting;
};

export type Connection = {
  id: string;
  userId: string;
  provider: Provider;
  settings: Record<string, unknown>;
  syncCursor: Record<string, unknown> | null;
  lastSyncedAt?: Date | null;
};

/** 연결에 성공했을 때 알려 줄 상태 (앱: complete 응답, 웹: /lab?{provider}=…) */
export type ConnectedStatus = ConnectedStatusValue;

export type ConnectorSyncResult = { created: string[]; scanned: number; skipped: Record<string, number> };

export type ConnectorSyncOutcome =
  | { connectionId: string; ok: true; result: ConnectorSyncResult }
  | { connectionId: string; ok: false; error: string; revoked: boolean; busy?: boolean };

/**
 * 연동 하나가 연결 틀(registry.ts)에 내놓는 것. 연결 시작 · callback · 동기화 · 계정 삭제가 서비스와 상관없이 이것만 부른다.
 * Google · Slack은 이 형태를 구현해 registry에 더하면 앱 연결 화면 · 주기 동기화에 그대로 붙는다.
 */
export type Connector = {
  provider: ConnectProvider;
  /** 권한 화면 주소 (state는 연결 틀이 만든다) */
  authorizeUrl: (state: string) => string;
  /** callback의 code를 토큰으로 바꿔 암호화해 저장하고, 무엇을 읽을 수 있게 됐는지 알려 준다 */
  connect: (admin: SupabaseClient, userId: string, code: string) => Promise<ConnectedStatus>;
  sync: (admin: SupabaseClient, connection: Connection, options: { deadline?: number }) => Promise<ConnectorSyncOutcome>;
  /** 서비스 쪽 토큰 폐기 (계정 삭제). 없으면 우리 쪽 토큰만 지운다 */
  revokeToken?: (token: unknown) => Promise<void>;
};
