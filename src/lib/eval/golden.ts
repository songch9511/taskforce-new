import { z } from "zod";

// 골든셋 케이스 형식. 한 케이스는 "시간 순서대로 들어오는 원문 묶음"과
// 그 결과로 남아야 하는 Action, 뽑으면 안 되는 문장을 담는다.

export const rejectReasonSchema = z.enum(["NOT_MY_ACTION", "INFO_ONLY", "TENTATIVE", "ALREADY_DONE"]);

export const goldenSourceSchema = z.object({
  id: z.string().min(1),
  kind: z.enum(["meeting", "message", "email", "doc", "note"]),
  occurred_at: z.iso.datetime({ offset: true }),
  text: z.string().min(1),
});

export const expectedActionSchema = z.object({
  title: z.string().min(1),
  owner: z.enum(["me", "other", "unknown"]),
  counterpart: z.string().optional(),
  due: z.iso.date().optional(),
  status: z.enum(["open", "done", "dropped"]).default("open"),
  // 이 Action의 근거가 되어야 하는 원문 인용 (source id + 원문 그대로의 구절)
  evidence: z
    .array(z.object({ source: z.string().min(1), quote: z.string().min(1) }))
    .min(1),
});

export const goldenCaseSchema = z.object({
  id: z.string().min(1),
  description: z.string().min(1),
  // real: 실제 사용자 원문(익명화), synthetic: 개발용으로 지어낸 원문. eval은 둘을 나눠 보고한다.
  origin: z.enum(["real", "synthetic"]).default("real"),
  user: z.object({ name: z.string().min(1) }),
  sources: z.array(goldenSourceSchema).min(1),
  expected_actions: z.array(expectedActionSchema),
  must_not_extract: z
    .array(z.object({ source: z.string().min(1), quote: z.string().min(1), reason: rejectReasonSchema }))
    .default([]),
});

export type GoldenCase = z.infer<typeof goldenCaseSchema>;

// 라벨링 실수를 잡는다: 인용이 원문에 실제로 있는지, source id가 존재하는지.
// 파이프라인의 "인용 실재 확인"과 같은 규칙을 골든셋 자체에도 적용한다.
export function findLabelErrors(golden: GoldenCase): string[] {
  const errors: string[] = [];
  const sources = new Map(golden.sources.map((s) => [s.id, s]));

  if (sources.size !== golden.sources.length) {
    errors.push("source id가 중복되었습니다");
  }

  const quotes = [
    ...golden.expected_actions.flatMap((a) => a.evidence.map((e) => ({ ...e, where: a.title }))),
    ...golden.must_not_extract.map((n) => ({ ...n, where: "must_not_extract" })),
  ];

  for (const { source, quote, where } of quotes) {
    const found = sources.get(source);
    if (!found) {
      errors.push(`[${where}] 없는 source를 가리킵니다: ${source}`);
    } else if (!normalize(found.text).includes(normalize(quote))) {
      errors.push(`[${where}] 인용이 원문 ${source}에 없습니다: "${quote}"`);
    }
  }

  return errors;
}

function normalize(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}
