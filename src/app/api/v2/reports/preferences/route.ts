import { authenticateRequest } from "@/lib/api/auth";
import { flagEnabled } from "@/lib/flags";
import { handleGetReportPreferences, handlePutReportPreferences } from "@/lib/reports/preferences";
import { loadReportPreferences, saveReportPreferences } from "@/lib/reports/store";

// 보고 설정 (0.2.0 H1). REPORTS_V2_ENABLED가 꺼져 있으면 404. 인증은 Bearer · 쿠키(쿠키 쓰기는 같은 출처만, authenticateRequest)
const deps = {
  enabled: () => flagEnabled("REPORTS_V2_ENABLED"),
  authenticate: authenticateRequest,
  load: loadReportPreferences,
  save: saveReportPreferences,
};

export async function GET(request: Request) {
  return handleGetReportPreferences(request, deps);
}

export async function PUT(request: Request) {
  return handlePutReportPreferences(request, deps);
}
