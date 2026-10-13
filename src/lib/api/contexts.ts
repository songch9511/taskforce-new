import type { UpdateContextResult } from "@/lib/context/store";
import type { CreateWorkContextRequest, UpdateWorkContextRequest, WorkContext } from "./contract";

import { createWorkContextRequestSchema, updateWorkContextRequestSchema, workContextResponseSchema } from "./contract";
import { errorResponse, parseBody, unauthorized } from "./respond";

type AppUser = { user: { id: string } };
const NOT_FOUND = () => errorResponse(404, "not_found", "없는 경로입니다.");
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function internalError(event: string, error: unknown): Response {
  const code = typeof (error as { code?: unknown } | null)?.code === "string" ? (error as { code: string }).code : undefined;
  console.error(JSON.stringify({ event, error: error instanceof Error ? error.name : "unknown", code }));
  return errorResponse(500, "internal_error", "프로젝트를 처리하지 못했습니다.");
}

type BaseDeps<User extends AppUser> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
};

export type CreateWorkContextDeps<User extends AppUser> = BaseDeps<User> & {
  create: (user: User, input: CreateWorkContextRequest) => Promise<WorkContext>;
};

export async function handleCreateWorkContext<User extends AppUser>(request: Request, deps: CreateWorkContextDeps<User>): Promise<Response> {
  if (!deps.enabled()) return NOT_FOUND();
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const body = await parseBody(request, createWorkContextRequestSchema);
  if ("error" in body) return body.error;
  try {
    const context = await deps.create(user, body.data);
    return Response.json(workContextResponseSchema.parse({ context }));
  } catch (error) {
    return internalError("context_create_failed", error);
  }
}

export type UpdateWorkContextDeps<User extends AppUser> = BaseDeps<User> & {
  update: (user: User, id: string, expectedVersion: number, changes: Omit<UpdateWorkContextRequest, "expected_version">) => Promise<UpdateContextResult>;
};

export async function handleUpdateWorkContext<User extends AppUser>(request: Request, id: string, deps: UpdateWorkContextDeps<User>): Promise<Response> {
  if (!deps.enabled()) return NOT_FOUND();
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!UUID.test(id)) return NOT_FOUND();
  const body = await parseBody(request, updateWorkContextRequestSchema);
  if ("error" in body) return body.error;
  const { expected_version: expectedVersion, ...changes } = body.data;
  try {
    const result = await deps.update(user, id, expectedVersion, changes);
    if (result.status === "not_found") return NOT_FOUND();
    if (result.status === "conflict") return errorResponse(409, "conflict", "그 사이 프로젝트가 바뀌었습니다. 다시 불러온 뒤 시도해 주세요.");
    return Response.json(workContextResponseSchema.parse({ context: result.context }));
  } catch (error) {
    return internalError("context_update_failed", error);
  }
}
