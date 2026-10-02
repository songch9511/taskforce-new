import { z } from "zod";

import { participantsSchema } from "@/lib/api/contract";
import { buildExecutionContext, type ExecutionContext } from "@/lib/execution/context";
import { quoteInText } from "@/lib/pipeline/text";

// 실행 골든셋(evals/draft · evals/plan)의 공통 모양: 사용자가 Action 하나에 맡긴 요청 + 그 Action · 근거 원문(합성).
// 원문은 실행기가 받을 것과 같게 연결 서비스(provider)를 붙인다: slack이면 context.ts가 빼야 한다.

const sourceSchema = z.object({
  id: z.string().min(1),
  kind: z.enum(["meeting", "message", "email", "doc", "note", "task"]),
  /** 원문을 가져온 연결 (connections.provider). 직접 붙여 넣은 원문은 null */
  provider: z.enum(["notion", "google", "gmail", "slack", "github"]).nullable().default(null),
  title: z.string().min(1).optional(),
  occurred_at: z.iso.datetime({ offset: true }),
  participants: participantsSchema.optional(),
  text: z.string().min(1),
});

export const executionCaseBaseSchema = z.object({
  id: z.string().min(1),
  description: z.string().min(1),
  origin: z.enum(["real", "synthetic"]).default("synthetic"),
  tags: z.array(z.string().min(1)).optional(),
  /** 요청한 시각 (오늘 날짜 계산 기준) */
  now: z.iso.datetime({ offset: true }),
  user: z.object({ name: z.string().min(1) }),
  /** 사용자가 맡긴 요청 (POST /api/v1/runs의 request, 1–2000자) */
  request: z.string().min(1).max(2000),
  action: z.object({
    title: z.string().min(1),
    status: z.enum(["open", "done", "dropped"]).default("open"),
    owner: z.enum(["me", "other", "unknown"]).default("me"),
    due_date: z.iso.date().optional(),
    counterpart: z.string().min(1).optional(),
  }),
  sources: z.array(sourceSchema),
  /** Action의 근거 구절 (원문 그대로) */
  evidence: z.array(z.object({ source: z.string().min(1), quote: z.string().min(1) })),
});

export type ExecutionCaseBase = z.infer<typeof executionCaseBaseSchema>;

/** 라벨링 실수: 원문 id 중복, 없는 원문을 가리키는 근거, 원문에 없는 근거 구절 */
export function findExecutionLabelErrors(golden: ExecutionCaseBase): string[] {
  const errors: string[] = [];
  const sources = new Map(golden.sources.map((s) => [s.id, s]));
  if (sources.size !== golden.sources.length) errors.push("source id가 중복되었습니다");
  for (const e of golden.evidence) {
    const source = sources.get(e.source);
    if (!source) errors.push(`근거: 없는 source ${e.source}`);
    else if (!quoteInText(e.quote, source.text)) errors.push(`근거가 원문 ${e.source}에 없습니다: "${e.quote}"`);
  }
  return errors;
}

/** 실행기가 만들 자료와 같은 코드(context.ts)로 만든다 */
export function executionContextOf(golden: ExecutionCaseBase): ExecutionContext {
  return buildExecutionContext({
    action: {
      title: golden.action.title,
      status: golden.action.status,
      owner: golden.action.owner,
      due_date: golden.action.due_date ?? null,
      counterpart: golden.action.counterpart ?? null,
    },
    sources: golden.sources.map((s) => ({
      id: s.id,
      kind: s.kind,
      title: s.title ?? null,
      occurredAt: new Date(s.occurred_at),
      provider: s.provider,
      purgeReason: null,
      text: s.text,
      participants: s.participants ?? null,
    })),
    evidence: golden.evidence.map((e) => ({ sourceId: e.source, quote: e.quote })),
  });
}

/** Slack에서 온 원문 글 (초안에 나오면 안 된다) */
export function slackTextsOf(golden: ExecutionCaseBase): string[] {
  return golden.sources.filter((s) => s.provider === "slack").map((s) => s.text);
}
