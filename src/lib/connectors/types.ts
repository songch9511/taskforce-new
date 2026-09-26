import type { ParticipantsInput } from "@/lib/api/contract";
import type { SourceKind } from "@/lib/pipeline/extract";

// 모든 연동(Notion · Gmail · Slack · GitHub)이 만들어 내는 공통 형태.
// 연동 모듈은 외부 항목을 이 형태로 바꾸기만 하고, 저장 · 추출은 ingest.ts가 한다.

export type Provider = "notion" | "gmail" | "slack" | "github";

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
};

export type Connection = {
  id: string;
  userId: string;
  provider: Provider;
  settings: Record<string, unknown>;
  syncCursor: Record<string, unknown> | null;
  lastSyncedAt?: Date | null;
};
