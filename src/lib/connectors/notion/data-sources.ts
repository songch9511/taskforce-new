import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { connectionSettingsSchema, type DataSourceSetting, type DataSourceSummary } from "@/lib/api/contract";

import { mergeConnectionSettings } from "../store";

import { dataSourceTitle, NotionError, NotionOAuthError, type NotionDataSource } from "./api";
import { withNotionClient } from "./run";
import { defaultStatusMap, isMeetingSource, suggestSetting, validateSetting, type SaveDataSourceRequest } from "./tasks";

// 연결에 공유된 Notion 데이터베이스의 역할(할 일 · 회의 · 무시)과 속성 매핑을 보여주고 확인받는다.
// 추정은 제안일 뿐이고, 확인한 설정만 동기화에 쓴다 (docs/INTEGRATIONS.md "Notion 할 일 DB"). 매핑이 분명한 할 일 DB는
// 동기화가 자동 확인한다(confirmedBy: auto). 사용자가 여기서 저장하면 사용자 확인으로 바뀐다.

export class DataSourceError extends Error {
  constructor(
    message: string,
    readonly status: 400 | 404,
  ) {
    super(message);
    this.name = "DataSourceError";
  }
}

async function loadSettings(admin: SupabaseClient, userId: string, connectionId: string) {
  const { data } = await admin
    .from("connections")
    .select("settings, provider")
    .eq("id", connectionId)
    .eq("user_id", userId)
    .maybeSingle()
    .throwOnError();
  if (!data || data.provider !== "notion") throw new DataSourceError("연결이 없습니다.", 404);
  return connectionSettingsSchema.parse(data.settings ?? {});
}

function summarize(ds: NotionDataSource, saved: DataSourceSetting | undefined): DataSourceSummary {
  const properties = Object.values(ds.properties).map(({ id, name, type }) => ({ id, name, type }));
  const statusOptions = Object.values(ds.properties).flatMap((p) =>
    (p.status?.options ?? []).map((o) => ({
      propertyId: p.id,
      id: o.id,
      name: o.name,
      group: p.status?.groups.find((g) => g.option_ids.includes(o.id))?.name ?? null,
    })),
  );
  return {
    id: ds.id,
    title: dataSourceTitle(ds),
    setting: saved?.confirmedAt ? saved : { ...suggestSetting(ds), ...(saved?.seenAt ? { seenAt: saved.seenAt } : {}) },
    confirmed: Boolean(saved?.confirmedAt),
    reachable: true,
    properties,
    statusOptions,
  };
}

/** 키 순서와 상관없이 비교한다 (jsonb는 키 순서를 바꿔 돌려준다). */
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonical((value as Record<string, unknown>)[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value ?? null);
}

/** 공유되지 않았거나 없는 데이터베이스만 null. 권한 끊김 · 토큰 갱신 거절(연결 만료) · 네트워크 오류는 그대로 올린다. */
const notFoundAsNull = (error: unknown) => {
  if (error instanceof NotionError && !(error instanceof NotionOAuthError) && (error.status === 404 || error.status === 400 || error.status === 403)) {
    return null;
  }
  throw error;
};

/** 설정은 저장돼 있지만 읽을 수 없는 데이터베이스: 목록에 남겨 "가져오지 않음"으로 바꿀 수 있게 한다. */
const unreachable = (id: string, saved: DataSourceSetting): DataSourceSummary => ({
  id,
  title: saved.title,
  setting: saved,
  confirmed: Boolean(saved.confirmedAt),
  reachable: false,
  properties: [],
  statusOptions: [],
});

export async function listDataSources(admin: SupabaseClient, userId: string, connectionId: string): Promise<DataSourceSummary[]> {
  const settings = await loadSettings(admin, userId, connectionId);
  const saved = settings.dataSources ?? {};
  return withNotionClient(admin, connectionId, async (client) => {
    const found = await client.searchDataSources();
    const summaries = found.map((ds) => summarize(ds, saved[ds.id]));
    // 검색에 없는 저장된 DB는 직접 읽어 본다: 검색 결과는 늦게 반영되기도 하고, 공유가 빠졌으면 404다.
    for (const id of Object.keys(saved).filter((id) => !found.some((ds) => ds.id === id))) {
      const ds = await client.dataSource(id).catch(notFoundAsNull);
      summaries.push(ds ? summarize(ds, saved[id]) : unreachable(id, saved[id]));
    }
    return summaries.sort((a, b) => Number(b.reachable) - Number(a.reachable) || (a.title ?? "").localeCompare(b.title ?? ""));
  });
}

export async function saveDataSource(
  admin: SupabaseClient,
  userId: string,
  connectionId: string,
  dataSourceId: string,
  request: SaveDataSourceRequest,
  now = new Date(),
): Promise<DataSourceSummary> {
  const before = await loadSettings(admin, userId, connectionId);
  const ds = await withNotionClient(admin, connectionId, (client) => client.dataSource(dataSourceId)).catch(notFoundAsNull);
  if (!ds) {
    // 읽을 수 없는 DB도 저장된 설정이 있으면 "가져오지 않음" · "글 원문"으로는 바꿀 수 있다 (동기화가 매번 실패를 남기지 않게).
    const saved = before.dataSources?.[dataSourceId];
    if (!saved || request.role === "tasks") {
      throw new DataSourceError("데이터베이스를 읽을 수 없습니다. Notion에서 이 데이터베이스를 Taskforce 연결에 다시 공유해 주세요.", 404);
    }
    const setting: DataSourceSetting = { role: request.role, title: saved.title, confirmedAt: now.toISOString() };
    await mergeConnectionSettings(admin, { id: connectionId, userId }, { dataSources: { [dataSourceId]: setting } });
    return unreachable(dataSourceId, setting);
  }
  const invalid = validateSetting(ds, request);
  if (invalid) throw new DataSourceError(invalid, 400);

  const statusProperty = request.props && Object.values(ds.properties).find((p) => p.id === request.props!.status.id);
  // 저장 직전에 다시 읽는다: 동기화가 그 사이 backfilledAt을 남겼을 수 있다.
  const current = await loadSettings(admin, userId, connectionId);
  const previous = current.dataSources?.[dataSourceId];
  const statusMap = request.role === "tasks" && statusProperty ? { ...defaultStatusMap(statusProperty), ...request.statusMap } : undefined;
  // 같은 매핑으로 이미 훑었으면 다시 훑지 않는다. 할 일 DB가 새로 되거나 매핑이 바뀌면 다음 동기화에서 열린 할 일을 다시 가져온다.
  const sameMapping =
    previous?.role === "tasks" &&
    request.role === "tasks" &&
    canonical(previous.props) === canonical(request.props) &&
    canonical(previous.statusMap) === canonical(statusMap);
  const setting: DataSourceSetting = {
    role: request.role,
    title: dataSourceTitle(ds),
    ...(request.props ? { props: request.props } : {}),
    ...(statusMap ? { statusMap } : {}),
    confirmedAt: now.toISOString(),
    ...(sameMapping && previous.backfilledAt ? { backfilledAt: previous.backfilledAt } : {}),
  };
  // 이 DB의 설정만 바꾼다: 다른 DB의 설정 · 동기화가 남기는 값(공유 상태 등)은 DB에 있는 값 그대로 (mergeConnectionSettings)
  await mergeConnectionSettings(admin, { id: connectionId, userId }, { dataSources: { [dataSourceId]: setting } });
  return summarize(ds, setting);
}

/** 연결 직후 점검 결과: 읽을 수 있는 것이 없음 / 회의록 DB가 안 보임 / 괜찮음 */
export type NotionCoverage = "empty" | "no_meetings" | "ok";

/**
 * 연결(다시 연결 포함) 직후: 이 토큰으로 무엇을 읽을 수 있는지 점검한다.
 * - 다시 연결할 때 선택 화면에서 아무것도 고르지 않고 끝내면, 전에 읽던 것까지 모두 끊긴다 (2026-09-27 실제로 겪음).
 * - 핵심 원문인 회의록 DB가 안 보이면 알려준다 (팀스페이스 맨 위 DB · 링크된 보기는 따로 골라야 한다).
 * 검색은 방금 공유한 것을 늦게 보여주기도 하므로, 전에 설정해 둔 DB는 직접 읽어 본다.
 */
export async function notionCoverage(admin: SupabaseClient, userId: string, connectionId: string): Promise<NotionCoverage> {
  const settings = await loadSettings(admin, userId, connectionId);
  return withNotionClient(admin, connectionId, async (client) => {
    const readable = [...(await client.searchDataSources())];
    for (const [id, setting] of Object.entries(settings.dataSources ?? {})) {
      if (setting.role === "ignore" || readable.some((ds) => ds.id === id)) continue;
      const ds = await client.dataSource(id).catch(notFoundAsNull);
      if (ds) readable.push(ds);
    }
    if (readable.length === 0 && (await client.searchPages()).pages.length === 0) return "empty";
    const meetingIds = new Set(Object.entries(settings.dataSources ?? {}).filter(([, s]) => s.confirmedAt && s.role === "text").map(([id]) => id));
    return readable.some((ds) => isMeetingSource(ds) || meetingIds.has(ds.id)) ? "ok" : "no_meetings";
  });
}
