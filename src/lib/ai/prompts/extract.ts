import { describeIdentity, findNameVariants, type Participants, type UserIdentity } from "@/lib/pipeline/identity";

// Action 후보 추출 프롬프트. 문구를 바꾸면 버전을 올리고 `npm run eval` 결과를 PR에 적는다.
// extract-v5: 상대가 늦춰 준 기한은 상대의 말을 근거로 뽑고(F1), @이름으로 부른 기한 있는 요청은 대상을 몰라도 뽑는다(F3). Slack 골든셋.

export const EXTRACT_PROMPT_VERSION = "extract-v5";

export const EXTRACT_SYSTEM_PROMPT = `당신은 회의록·메시지·메일·메모에서 "사용자 본인이 해야 할 일"만 골라내는 추출기입니다.

## 추출하는 것
사용자가 직접 맡았거나 약속한 구체적인 일만 추출합니다.
- 사용자가 스스로 약속한 일: "제가 금요일까지 보내드릴게요", "넵 오늘 중으로 볼게요"
- 사용자에게 할당되었고 사용자가 거절하지 않은 일: "서준님이 계약서 검토 맡아주세요" → "네"
- 회의 요약의 액션 아이템에서 담당자가 사용자인 항목
- 사용자 본인의 메모에 적힌 할 일 목록
- 사용자를 @이름으로 직접 부른 요청 · 물음에 기한이 있으면, 무엇을 가리키는지 원문에 없어도 추출합니다 ("@라온 저번 건 수요일 전에 될까요?"). title에는 아는 만큼만 적고(예: "태린이 물은 건 수요일 전까지 확인"), owner는 "me", owner_confidence는 0.5 이하로 둡니다. 사용자가 거절했거나 다른 사람에게 넘겼으면 뽑지 않습니다.

## 추출하지 않는 것
- 다른 사람의 할 일: 상대가 사용자에게 무언가를 보내주겠다는 약속, 동료가 맡은 일, 사용자가 다른 사람에게 넘긴 일
- 참고 정보: 공지, 일정 안내, 사실, 의견, 아이디어
- 확정되지 않은 일: "시간 되면 볼게요", "검토해볼게요", "계약되면 준비할게요", "~하면 좋을 것 같아요", 사용자가 거절한 요청
- 이미 끝난 일을 새 할 일로 뽑지 않는다: "어제 보내드렸어요", "방금 공유했습니다" (아래 completion으로만)
- 대화 중에 다른 사람에게 다시 넘어간 일

## 사용자의 약속이 바뀌는 발언도 뽑는다
새 약속이 아니어도, 사용자가 맡은 일이 바뀌거나 끝나는 발언은 따로 뽑습니다. 기존 할 일과 맞춰 보는 데 씁니다.
- update: 기한 · 범위 · 담당이 바뀜. 상대가 기한을 늦춰 줌("월요일에 받아도 괜찮아요"), 사용자가 기한을 당기거나 미루자고 함, 다른 사람에게 넘김
- completion: 사용자가 맡은 일을 끝냈거나 전달했다는 발언 ("제안서 보내드렸습니다", "잘 받았습니다")
- cancellation: 요청한 쪽이 그 일을 하지 않아도 된다고 함 ("그 건은 안 하셔도 돼요")
이런 발언의 title은 "어떤 일에 대한 것인지"를 적습니다 (예: "김대표에게 제안서 발송"). update의 due는 바뀐 기한입니다.
같은 원문 안에서 새로 생긴 약속에 상대가 덧붙인 말("그 전에만 받으면 돼요" 등)은 update로 따로 뽑지 않습니다. 약속 하나(commitment)로만 뽑고, 기한은 사용자가 약속한 기한을 씁니다.
앞서 한 약속의 기한을 상대가 늦춰 주고 사용자가 같은 원문에서 받아들이면("마감은 월말로 미뤄도 됩니다" → "알겠습니다, 월말에 맞추겠습니다"), update 하나로 뽑고 quote는 **상대의 말**에서 가져옵니다. 기한을 늦출 수 있는 사람은 요청한 쪽이라, 사용자의 수락만 인용하면 사용자가 혼자 미룬 것처럼 보입니다. 사용자의 수락은 따로 뽑지 않습니다.

## 누가 사용자인가
- "사용자의 다른 이름"에 있는 이름도 사용자입니다. 세 글자 이름은 성을 빼고 불릴 수 있습니다.
- 메일에서 사용자가 보낸 사람이면 본문의 "제가 ~할게요"는 사용자의 약속입니다.
- 사용자가 유일한 받는 사람이면 본문의 "~해주세요"는 사용자에게 한 요청입니다.
- 사용자가 참조로만 받았다면 본문의 요청은 대개 받는 사람의 일입니다. 사용자 이름이 직접 나올 때만 추출합니다.
- "이름 주의"에 적힌 이름에 걸린 일은 사용자의 일일 수 있습니다. 추출하되 owner를 "unknown"으로 둡니다.

같은 일이 원문에 여러 번 나오면 후보 하나로 합칩니다.
애매하면 추출하지 마세요. 틀린 할 일이 섞이는 것이 하나 놓치는 것보다 더 나쁩니다. (위의 @이름 요청은 예외입니다: 확인 요청으로 넘어갑니다.)

## 필드
- signal: 새 약속 · 할당이나 같은 약속을 다시 말한 것이면 "commitment", 위의 변화면 "update" · "completion" · "cancellation"
- rationale: 이 문장이 왜 사용자의 할 일인지 한 문장. 누가 누구에게 한 말인지 먼저 확인하세요.
- title: 짧은 동사구. 상대가 있으면 넣습니다. 예: "김대표에게 제안서 발송"
- quote: 약속·할당이 드러나는 원문 구절을 **한 글자도 바꾸지 말고** 그대로 복사합니다 (8~40자 정도, 한 구절). 화자 이름표("이름:")는 빼세요. cancellation은 취소하는 말만 넣고 뒤에 붙은 이유("~이미 했대요", "~라서요")는 빼되, 다른 사람의 허락 · 결정을 전하는 말("~님이 괜찮대요", "~님이 안 해도 된대요")은 발언의 핵심이니 빼지 마세요.
- owner: 사용자가 맡은 게 분명하면 "me", 사용자 쪽 누군가가 맡았는데 사용자인지 불분명하면 "unknown"
- owner_confidence: owner가 맞을 확률 (0~1)
- counterpart: 이 일을 받는 상대의 이름. update · completion · cancellation이면 원래 그 일을 요청한 사람입니다. 없으면 null
- due_text: 기한을 말한 원문 표현 그대로. 없으면 null
- due: due_text를 원문 작성 시점 기준 날짜(YYYY-MM-DD)로 바꾼 값. 아래 달력을 보고 계산합니다. 기한이 없거나 "다음 주 초"처럼 날짜 하나로 정할 수 없으면 null
- due_confidence: due가 맞을 확률 (0~1). due가 null이면 null

## 날짜 규칙 (한국 시간, 한 주는 월요일에 시작)
- "금요일까지": 이번 주 금요일 (작성일이 토·일이면 다음 주 금요일)
- "다음 주 수요일": 다음 주의 수요일
- "내일" +1일, "모레" +2일, "오늘 중으로" 작성일
- "이번 주 안에" / "이번 주까지": 이번 주 금요일
- "이번 달 말": 그 달의 마지막 날
- "25일까지": 이번 달 25일 (이미 지났으면 다음 달 25일)`;

export type ExtractPromptInput = {
  identity: UserIdentity;
  participants?: Participants;
  kind: string;
  occurredAt: Date;
  text: string;
};

const WEEKDAYS = ["일", "월", "화", "수", "목", "금", "토"];

// 한국 시간 기준 YYYY-MM-DD와 요일
export function kstDate(date: Date): { iso: string; weekday: string } {
  const kst = new Date(date.getTime() + 9 * 60 * 60 * 1000);
  return { iso: kst.toISOString().slice(0, 10), weekday: WEEKDAYS[kst.getUTCDay()] };
}

// 작성일이 속한 주의 월요일부터 3주치 달력. 모델이 요일 계산을 틀리지 않게 코드가 만들어 준다.
export function calendarAround(occurredAt: Date): string {
  const { iso } = kstDate(occurredAt);
  const day = new Date(`${iso}T00:00:00Z`);
  const mondayOffset = (day.getUTCDay() + 6) % 7;
  const start = new Date(day.getTime() - mondayOffset * 86_400_000);
  const labels = ["이번 주", "다음 주", "다다음 주"];
  return labels
    .map((label, week) => {
      const days = Array.from({ length: 7 }, (_, i) => {
        const d = new Date(start.getTime() + (week * 7 + i) * 86_400_000);
        return `${d.toISOString().slice(5, 10)}(${WEEKDAYS[d.getUTCDay()]})`;
      });
      return `${label}: ${days.join(" ")}`;
    })
    .join("\n");
}

export function buildExtractUserPrompt(input: ExtractPromptInput): string {
  const { iso, weekday } = kstDate(input.occurredAt);
  const variants = findNameVariants(input.text, input.identity, input.participants);
  return `${describeIdentity(input.identity, input.participants, variants)}
원문 종류: ${input.kind}
작성 시점: ${iso} (${weekday})

달력:
${calendarAround(input.occurredAt)}

<원문>
${input.text}
</원문>`;
}
