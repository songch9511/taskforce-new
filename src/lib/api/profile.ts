import type { UserIdentity } from "@/lib/pipeline/identity";

import { profileSchema, type ApiError, type Profile } from "./contract";

// GET · PUT /api/v1/profile 처리와, 프로필 · 로그인 정보 · 요청을 합쳐 "원문 속 사용자"를 만드는 규칙.

export const EMPTY_PROFILE: Profile = { display_name: null, aliases: [], emails: [] };

type AuthUser = { name: string; email: string | null };

/** 계정 정보에서 기본 이름을 고른다: Apple · Google이 준 이름 → 이메일 앞부분 */
export function accountDisplayName(metadata: Record<string, unknown> | undefined, email: string | null): string {
  for (const key of ["full_name", "name"]) {
    const value = metadata?.[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return email?.split("@")[0] ?? "나";
}

/**
 * 파이프라인에 넘길 사용자 정보. 이름은 요청 → 프로필 → 계정 순서로 고른다.
 * 요청에서 이름을 바꿨으면 프로필 이름도 별칭으로 남겨 둔다.
 */
export function resolveIdentity(profile: Profile | null, auth: AuthUser, requestName?: string): UserIdentity {
  const p = profile ?? EMPTY_PROFILE;
  const baseName = p.display_name ?? auth.name;
  const name = requestName ?? baseName;
  const aliases = unique([...(name !== baseName ? [baseName] : []), ...p.aliases]).filter((alias) => alias !== name);
  const emails = unique([...(auth.email ? [auth.email] : []), ...p.emails].map((e) => e.toLowerCase()));
  return { name, aliases, emails };
}

function unique(values: string[]): string[] {
  return [...new Set(values.map((v) => v.trim()).filter(Boolean))];
}

export type ProfileDeps<User> = {
  authenticate: (request: Request) => Promise<User | null>;
  load: (user: User) => Promise<Profile | null>;
  save: (user: User, profile: Profile) => Promise<void>;
};

export async function handleGetProfile<User>(request: Request, deps: ProfileDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return errorResponse(401, "unauthorized", "로그인이 필요합니다.");
  return Response.json((await deps.load(user)) ?? EMPTY_PROFILE);
}

export async function handlePutProfile<User>(request: Request, deps: ProfileDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return errorResponse(401, "unauthorized", "로그인이 필요합니다.");

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return errorResponse(400, "invalid_request", "JSON 본문이 필요합니다.");
  }
  const parsed = profileSchema.safeParse(body);
  if (!parsed.success) {
    const fields = [...new Set(parsed.error.issues.map((issue) => issue.path.join(".") || "(본문)"))];
    return errorResponse(400, "invalid_request", `잘못된 필드: ${fields.join(", ")}`);
  }

  const profile: Profile = {
    display_name: parsed.data.display_name,
    aliases: unique(parsed.data.aliases),
    emails: unique(parsed.data.emails.map((e) => e.toLowerCase())),
  };
  try {
    await deps.save(user, profile);
  } catch (error) {
    console.error("프로필 저장 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "프로필을 저장하지 못했습니다.");
  }
  return Response.json(profile);
}

function errorResponse(status: number, code: ApiError["error"]["code"], message: string): Response {
  return Response.json({ error: { code, message } } satisfies ApiError, { status });
}
