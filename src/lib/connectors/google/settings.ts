import { z } from "zod";

import type { GoogleAccount } from "./oauth";

// Google 연결(google · gmail)의 설정 (connections.settings, 순수 함수). 앱 · /lab은 이 값을 직접 읽는다.
// 쓰기는 바꿀 키만 DB 함수로 합친다 (store.ts mergeConnectionSettings · addConnectionStats): 계정 · 범위와 통계가 서로를 덮지 않는다.

/**
 * 동기화마다 더하는 개수 (이유 코드별, 글자 · 주소 없이). 원문이 남지 않는 거른 메일을 세는 유일한 곳이다 (8장, 원칙 6).
 * 더하기는 DB 함수 add_connection_stats가 한다 (20261017000000): 모양이 다르면 새로 센다.
 */
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

/** 연결(다시 연결 포함)할 때 바꿀 설정: 계정 · 받은 범위. 통계 등 나머지 값은 건드리지 않는다 (mergeConnectionSettings의 set) */
export function accountSettings(account: GoogleAccount, scopes: string[]): Pick<GoogleSettings, "googleUserId" | "email" | "scopes"> {
  return { googleUserId: account.sub, email: account.email, scopes };
}
