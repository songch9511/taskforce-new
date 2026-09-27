import { describeIdentity, findNameVariants, type Participants, type UserIdentity } from "@/lib/pipeline/identity";

import { calendarAround, kstDate } from "./extract";

// 빠진 할 일 신고 프롬프트. 사용자가 원문 구절을 골라 "여기 내 할 일이 있다"고 알려준 뒤, 그 구절 하나만 할 일로 정리한다.
// 추출 프롬프트(extract.ts)와 따로 버전을 관리한다. 문구를 바꾸면 버전을 올리고 `npm run eval` 결과를 PR에 적는다.

export const MISSING_PROMPT_VERSION = "missing-v1";

export const MISSING_SYSTEM_PROMPT = `당신은 사용자가 직접 알려준 할 일을 정리하는 도우미입니다.

사용자는 원문(회의록·메시지·메일·메모)에서 아래 "신고한 구절"을 골라 "여기에 내가 해야 할 일이 있는데 빠졌다"고 알려줬습니다.
사용자의 말을 믿으세요. 이 구절에 사용자 본인의 할 일이 있다고 보고, 그 할 일 하나를 정리합니다.
할 일인지 아닌지 다시 판단하지 않습니다. 앞뒤 문맥은 무엇을 · 누구에게 · 언제까지 하는지 알아내는 데만 씁니다.

## 필드
- title: 짧은 동사구. 상대가 있으면 넣습니다. 예: "김대표에게 제안서 발송". 문맥에 나온 말로만 씁니다
- counterpart: 이 일을 받는 상대의 이름. 없으면 null
- due_text: 기한을 말한 원문 표현 그대로 (신고한 구절이나 앞뒤 문맥에서). 없으면 null
- due: due_text를 원문 작성 시점 기준 날짜(YYYY-MM-DD)로 바꾼 값. 아래 달력을 보고 계산합니다. 기한이 없거나 "다음 주 초"처럼 날짜 하나로 정할 수 없으면 null
- due_confidence: due가 맞을 확률 (0~1). due가 null이면 null

## 날짜 규칙 (한국 시간, 한 주는 월요일에 시작)
- "금요일까지": 이번 주 금요일 (작성일이 토·일이면 다음 주 금요일)
- "다음 주 수요일": 다음 주의 수요일
- "내일" +1일, "모레" +2일, "오늘 중으로" 작성일
- "이번 주 안에" / "이번 주까지": 이번 주 금요일
- "이번 달 말": 그 달의 마지막 날
- "25일까지": 이번 달 25일 (이미 지났으면 다음 달 25일)`;

export type MissingPromptInput = {
  identity: UserIdentity;
  participants?: Participants;
  kind: string;
  occurredAt: Date;
  /** 사용자가 고른 구절 */
  quote: string;
  /** 구절 앞뒤 원문 (quoteContext). 원문 전체는 보내지 않는다 */
  context: string;
};

export function buildMissingUserPrompt(input: MissingPromptInput): string {
  const { iso, weekday } = kstDate(input.occurredAt);
  const variants = findNameVariants(input.context, input.identity, input.participants);
  return `${describeIdentity(input.identity, input.participants, variants)}
원문 종류: ${input.kind}
작성 시점: ${iso} (${weekday})

달력:
${calendarAround(input.occurredAt)}

<신고한 구절>
${input.quote}
</신고한 구절>

<앞뒤 문맥>
${input.context}
</앞뒤 문맥>`;
}
