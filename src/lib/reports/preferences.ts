import {
  REPORT_PREFERENCE_DEFAULTS,
  reportPreferencesRequestSchema,
  type ReportPreferences,
  type ReportPreferencesRequest,
} from "@/lib/api/contract";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";

// GET · PUT /api/v2/reports/preferences (Mac Reports 탭, H2). REPORTS_V2_ENABLED가 꺼져 있으면 404 (route가 없는 것처럼).
// 저장한 적이 없으면 D06 기본값과 time_zone null을 돌려준다: 서버는 시간대를 추측하지 않고, Mac이 PUT으로 자기 시간대를 보낸다.

export const DEFAULT_REPORT_PREFERENCES: ReportPreferences = { ...REPORT_PREFERENCE_DEFAULTS, time_zone: null, saved: false };

export type ReportPreferencesDeps<User> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  load: (user: User) => Promise<ReportPreferences | null>;
  save: (user: User, prefs: ReportPreferencesRequest) => Promise<ReportPreferences>;
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
    return Response.json(await deps.save(user, body.data));
  } catch (error) {
    console.error("보고 설정 저장 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "보고 설정을 저장하지 못했습니다.");
  }
}
