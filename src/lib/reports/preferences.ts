import {
  REPORT_PREFERENCE_DEFAULTS,
  reportPreferencesRequestSchema,
  type ReportPreferences,
  type ReportPreferencesRequest,
} from "@/lib/api/contract";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";

// GET · PUT /api/v2/reports/preferences (Mac Reports 탭, H2). REPORTS_V2_ENABLED가 꺼져 있으면 404 (route가 없는 것처럼).
// 저장한 적이 없으면 D06 기본값 · time_zone null · version null · saved false: 서버는 시간대를 추측하지 않고, Mac이 PUT으로 자기 시간대를 보낸다.
// PUT은 낙관적 동시성: expected_version이 서버의 version과 다르면(다른 기기가 먼저 바꿨거나, null인데 이미 있음) 409 conflict.
// 앱은 다시 GET해서 보여 주고, 덮어쓰지 않는다 (docs/FEATURE_MAP.md 3-8 "H2가 할 일").

export const DEFAULT_REPORT_PREFERENCES: ReportPreferences = { ...REPORT_PREFERENCE_DEFAULTS, time_zone: null, saved: false, version: null };

export type ReportPreferencesDeps<User> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  load: (user: User) => Promise<ReportPreferences | null>;
  /** 저장된 설정, 또는 expected_version이 맞지 않으면 null (409) */
  save: (user: User, prefs: ReportPreferencesRequest) => Promise<ReportPreferences | null>;
};

const disabled = () => errorResponse(404, "not_found", "없는 경로입니다.");

export async function handleGetReportPreferences<User>(request: Request, deps: ReportPreferencesDeps<User>): Promise<Response> {
  if (!deps.enabled()) return disabled();
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  try {
    return Response.json((await deps.load(user)) ?? DEFAULT_REPORT_PREFERENCES);
  } catch (error) {
    console.error("보고 설정 조회 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "보고 설정을 불러오지 못했습니다.");
  }
}

export async function handlePutReportPreferences<User>(request: Request, deps: ReportPreferencesDeps<User>): Promise<Response> {
  if (!deps.enabled()) return disabled();
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const body = await parseBody(request, reportPreferencesRequestSchema);
  if ("error" in body) return body.error;
  try {
    const saved = await deps.save(user, body.data);
    if (!saved) return errorResponse(409, "conflict", "다른 기기에서 먼저 바꿨습니다. 다시 불러와 주세요.");
    return Response.json(saved);
  } catch (error) {
    console.error("보고 설정 저장 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "보고 설정을 저장하지 못했습니다.");
  }
}
