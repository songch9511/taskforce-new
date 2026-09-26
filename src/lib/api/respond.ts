import type { z } from "zod";

import type { ApiError } from "./contract";

// Route Handler 공통: 오류 응답과 본문 검증. 오류 메시지에 요청 값(원문일 수 있음)을 담지 않는다.

export function errorResponse(status: number, code: ApiError["error"]["code"], message: string): Response {
  return Response.json({ error: { code, message } } satisfies ApiError, { status });
}

export const unauthorized = () => errorResponse(401, "unauthorized", "로그인이 필요합니다.");

export async function parseBody<T extends z.ZodType>(request: Request, schema: T): Promise<{ data: z.infer<T> } | { error: Response }> {
  let body: unknown;
  try {
    const text = await request.text();
    body = text ? JSON.parse(text) : {};
  } catch {
    return { error: errorResponse(400, "invalid_request", "JSON 본문이 필요합니다.") };
  }
  const parsed = schema.safeParse(body);
  if (!parsed.success) {
    const fields = [...new Set(parsed.error.issues.map((issue) => issue.path.join(".") || "(본문)"))];
    return { error: errorResponse(400, "invalid_request", `잘못된 필드: ${fields.join(", ")}`) };
  }
  return { data: parsed.data };
}
