import { resolvePathConflictRequestSchema, type ResolvePathConflictResponse } from "./contract";
import { errorResponse, parseBody, unauthorized } from "./respond";

// POST /api/v2/path-conflicts/{lease_id}/resolve 처리 (OA D4b-s). 인증 · gate · 해소를 인자로 받아 Route Handler 밖에서 테스트한다 (C3 handler와 같은 모양).
//  - gate가 꺼져 있으면 404: 인증 · DB를 부르지 않는다 (REVIEW_V2_ENABLED ∧ 켜진 adapter가 하나라도 있을 때만 연다 — Review가 충돌을 보이는 조건과 같다).
//  - 쿠키로 인증하는 쓰기(POST)의 CSRF는 authenticateRequest가 본다.
//  - 오류 본문에 요청 값을 담지 않는다. 로그에는 오류 이름만 남긴다 (lease id · 경로 · 본문을 남기지 않는다).

type AppUser = { user: { id: string } };

export type PathConflictResolveOutcome = { status: "resolved" | "stale" | "not_found" };

export type ResolvePathConflictDeps<User extends AppUser> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  /** D3c-2 resolve_path_conflict 한 번 (충돌 열 해소 · 지표가 한 트랜잭션). stale = 옛 version이거나 이미 해소됨 */
  resolve: (user: User, input: { leaseId: string; keep: "holder" | "later"; conflictVersion: number }) => Promise<PathConflictResolveOutcome>;
};

const NOT_FOUND = "없는 경로입니다.";
const CONFLICT_NOT_FOUND = "충돌이 없습니다.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NO_STORE = { "Cache-Control": "no-store" };

/**
 * POST /api/v2/path-conflicts/{lease_id}/resolve { keep, conflict_version } — 같은 경로를 쓴 두 세션 중 한쪽을 남긴다.
 * 200 { status: "resolved" } · 409 conflict(옛 version이거나 이미 해소됐다: 쓰기 0 · 지표 0, 앱은 자동 재시도 없이 Review를 다시 읽는다) · 404(gate 꺼짐 · 없는 lease · 남의 lease) · 400 · 401.
 * 효과는 D3c-2 SQL 그대로다: 멈춘 run을 다시 시작하지 않고 파일을 되돌리지 않는다.
 */
export async function handleResolvePathConflict<User extends AppUser>(request: Request, leaseId: string, deps: ResolvePathConflictDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", NOT_FOUND);
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!UUID.test(leaseId)) return errorResponse(404, "not_found", CONFLICT_NOT_FOUND);
  const body = await parseBody(request, resolvePathConflictRequestSchema);
  if ("error" in body) return body.error;
  try {
    const result = await deps.resolve(user, { leaseId, keep: body.data.keep, conflictVersion: body.data.conflict_version });
    switch (result.status) {
      case "resolved":
        return Response.json({ status: "resolved" } satisfies ResolvePathConflictResponse, { headers: NO_STORE });
      case "stale":
        return errorResponse(409, "conflict", "그 사이 충돌이 바뀌었거나 이미 해소됐습니다. 다시 불러온 뒤 시도해 주세요.");
      case "not_found":
        return errorResponse(404, "not_found", CONFLICT_NOT_FOUND);
    }
  } catch (error) {
    console.error(JSON.stringify({ event: "path_conflict_resolve_failed", error: error instanceof Error ? error.name : "unknown" }));
    return errorResponse(500, "internal_error", "충돌을 해소하지 못했습니다.");
  }
}
