import { createSourceRequestSchema, type ApiError, type CreateSourceRequest, type CreateSourceResponse } from "./contract";

// POST /api/v1/sources 처리. 인증 · 저장 · 백그라운드 실행을 인자로 받아 Route Handler 밖에서 테스트한다.

export type NewSource = {
  kind: CreateSourceRequest["kind"];
  raw_text: string;
  occurred_at: string;
  title: string | null;
  external_url: string | null;
};

export type CreateSourceDeps<User> = {
  authenticate: (request: Request) => Promise<User | null>;
  insertSource: (user: User, source: NewSource) => Promise<string>;
  /** 202를 돌려준 뒤 파이프라인을 돌린다 (Next.js after) */
  schedule: (user: User, sourceId: string, source: NewSource, userName: string | undefined) => void;
  now?: () => Date;
};

export async function handleCreateSource<User>(request: Request, deps: CreateSourceDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return errorResponse(401, "unauthorized", "로그인이 필요합니다.");

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return errorResponse(400, "invalid_request", "JSON 본문이 필요합니다.");
  }

  const parsed = createSourceRequestSchema.safeParse(body);
  if (!parsed.success) {
    // 값은 원문일 수 있어 돌려주지 않고, 어느 필드가 틀렸는지만 알려준다.
    const fields = [...new Set(parsed.error.issues.map((issue) => issue.path.join(".") || "(본문)"))];
    return errorResponse(400, "invalid_request", `잘못된 필드: ${fields.join(", ")}`);
  }

  const request_ = parsed.data;
  const source: NewSource = {
    kind: request_.kind,
    raw_text: request_.text,
    occurred_at: request_.occurred_at ?? (deps.now?.() ?? new Date()).toISOString(),
    title: request_.title ?? null,
    external_url: request_.external_url ?? null,
  };

  let sourceId: string;
  try {
    sourceId = await deps.insertSource(user, source);
  } catch (error) {
    console.error("원문 저장 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "원문을 저장하지 못했습니다.");
  }

  deps.schedule(user, sourceId, source, request_.user_name);
  return Response.json({ source_id: sourceId, status: "pending" } satisfies CreateSourceResponse, { status: 202 });
}

function errorResponse(status: number, code: ApiError["error"]["code"], message: string): Response {
  return Response.json({ error: { code, message } } satisfies ApiError, { status });
}
