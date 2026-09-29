import { z } from "zod";

import type { GoogleAccount } from "./oauth";

// Google 연결(google · gmail)의 설정 (connections.settings, 순수 함수). 앱 · /lab은 이 값을 직접 읽는다.

/** 동기화마다 더하는 개수 (이유 코드별, 글자 · 주소 없이). 원문이 남지 않는 거른 메일을 세는 유일한 곳이다 (8장, 원칙 6) */
const statsSchema = z.object({ since: z.string(), counts: z.record(z.string(), z.number()) });

export const googleSettingsSchema = z.looseObject({
  /** 연결한 Google 계정의 sub (연결 키) */
  googleUserId: z.string(),
  /** 연결한 Google 주소 (확인된 주소만). "원문 속 나" · 원본 링크의 authuser */
  email: z.string().nullable(),
  /** 이용자가 허용한 범위 (G10) */
  scopes: z.array(z.string()),
  stats: statsSchema.optional(),
});
export type GoogleSettings = z.infer<typeof googleSettingsSchema>;

/** 연결(다시 연결 포함)한 계정 · 범위를 남긴다. 통계 등 나머지 값은 그대로 */
export function withAccount(settings: Record<string, unknown>, account: GoogleAccount, scopes: string[]): Record<string, unknown> {
  return { ...settings, googleUserId: account.sub, email: account.email, scopes };
}

/** 이번 동기화의 개수를 통계에 더한다. 더할 것이 없으면 null (쓰지 않는다) */
export function withStats(settings: Record<string, unknown>, counts: Partial<Record<string, number>>, now: Date): Record<string, unknown> | null {
  const added = Object.entries(counts).filter((entry): entry is [string, number] => (entry[1] ?? 0) > 0);
  if (added.length === 0) return null;
  const saved = statsSchema.safeParse(settings.stats);
  const stats = saved.success ? { since: saved.data.since, counts: { ...saved.data.counts } } : { since: now.toISOString(), counts: {} as Record<string, number> };
  for (const [key, count] of added) stats.counts[key] = (stats.counts[key] ?? 0) + count;
  return { ...settings, stats };
}
