# 오탐 방지와 진실 판정 기준

두 가지를 다룹니다.

1. **Judge AI (Jev)**: 추출된 Action 후보를 독립적으로 검증해 오탐을 줄이는 단계
2. **진실 판정 기준**: 여러 소스가 서로 다른 말을 할 때 무엇을 사실로 볼지 정하는 규칙

핵심 설계 원칙은 하나입니다.

> **LLM은 "누가 언제 무엇을 말했는가(Claim)"만 뽑는다. "그래서 지금 무엇이 사실인가"는 코드가 정한다.**

LLM이 최종 값을 바로 정하면 틀려도 이유를 알 수 없고, 같은 입력에 다른 답이 나옵니다.
판정을 결정적인 코드 규칙으로 두면 모든 값에 "왜 이 값인지"를 설명할 수 있고, 단위 테스트로 고정할 수 있습니다.

---

## 1. Judge AI: Jev (검증 단계)

### 파이프라인 위치

```
Source → ① 추출기(Extractor) → ② 기계적 검증 → ③ Jev 판정 → ④ 매칭 → ⑤ 진실 판정(코드) → 반영
```

### ② 기계적 검증 (LLM 없이, 먼저)

싸고 확실한 것부터 걸러냅니다. 이 단계에서 걸러지는 오탐이 생각보다 많습니다.

- **인용 실재 확인**: 후보의 `quote`가 원문에 실제로 있는지 문자열로 대조합니다(공백·문장부호 정규화 후). 없으면 환각이므로 즉시 폐기합니다.
- **날짜 정합성**: "금요일"을 정규화한 날짜가 원문 작성 시점(`occurred_at`) 기준으로 맞는지 코드로 다시 계산합니다.
- **스키마 검증**: zod 검증에 실패하면 폐기합니다.

### ③ Judge: Jev (TypeSafe System One 모델)

Judge에는 [Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev)를 씁니다.
Jev는 글을 생성하지 않는 **판정 전용 모델**입니다. 상태(`state`)와 타입이 정해진 질문(`questions`)을 보내면
**보정된(calibrated) 확률**만 돌려줍니다. 그래서 역할을 이렇게 나눕니다.

| 일 | 모델 | 이유 |
|---|---|---|
| Claim 추출 (제목, 인용, 날짜 표현 생성) | 생성형 LLM | 글을 만들어야 하는 일. Jev는 못 합니다 |
| 추출 결과 검증, 속성 분류, 매칭 판정 | **Jev** | 정해진 선택지 중 고르기 + 확률이 필요한 일 |

LLM이 스스로 매기는 "확신도"는 잘 보정되어 있지 않습니다.
Jev의 확률은 보정을 목표로 학습되어 있어서 **"P(내 약속) < 0.8이면 확인 요청"** 같은 임계값을 그대로 걸 수 있습니다.
이것이 Jev를 쓰는 핵심 이유입니다.

#### API

- 엔드포인트: `POST https://openrouter.ai/api/alpha/decisions` (OpenRouter Decisions API, **chat completions와 다름**. 채팅 SDK로는 호출 불가)
- 인증: `Authorization: Bearer $OPENROUTER_API_KEY`
- 모델: `typesafe/jev-1.13` (eval 재현성을 위해 `~latest` 대신 **버전 고정**)
- 요청: `{ "model", "state", "questions" }`. `state`에는 문자열, JSON 객체, 텍스트 배열을 넣을 수 있습니다.
- 질문 타입과 응답:
  - `noul` → `{"type":"noul","noul":0.93}` (예일 확률)
  - `choice` → `{"type":"choice","choice":"key","confidence":…,"probabilities":{…}}`
  - `score` → `{"type":"score","score":1.4,"probabilities":{…}}` (순서 있는 척도, 소수값 가능)
- 비용: 입력 토큰만 과금되고 출력은 무료입니다. 후보 하나에 질문 여러 개를 **한 번에** 묻습니다.

#### 후보 검증 요청 (후보 1개당 1회 호출)

`state`에는 후보와 인용 주변 원문만 넣습니다. 추출기의 추론은 넣지 않습니다.

```jsonc
{
  "model": "typesafe/jev-1.13",
  "state": {
    "user": "<사용자 이름>",
    "candidate": { "title": "제안서 발송", "due_text": "금요일까지", "quote": "금요일까지 제안서 보내드릴게요" },
    "context": "…인용 앞뒤 원문 구간…",
    "source": { "kind": "meeting", "occurred_at": "2026-09-22" }
  },
  "questions": {
    "is_my_commitment": { "type": "noul", "instructions": "Did the user personally commit to or get assigned this action?" },
    "is_actionable":    { "type": "noul", "instructions": "Is this a concrete action, not reference info, an opinion, or an idea?" },
    "already_done":     { "type": "noul", "instructions": "Does the context show this action is already completed?" },
    "certainty": { "type": "choice", "instructions": "How firm is the commitment?",
      "criteria": { "firm": "Explicit promise or assignment", "tentative": "Maybe, considering, possibly", "none": "No commitment" } },
    "speaker_role": { "type": "choice", "instructions": "Who made the statement in the quote?",
      "criteria": { "me": "The user", "counterpart": "The person the action is for", "third_party": "Someone else" } },
    "directness": { "type": "choice", "instructions": "Is the statement first-hand or reported?",
      "criteria": { "first_hand": "Speaker states it directly", "reported": "Relays what someone else said" } },
    "audience": { "type": "choice", "instructions": "Was this said to the counterpart or a private note?",
      "criteria": { "shared": "Communicated to the counterpart", "private": "User's own note or internal" } }
  }
}
```

`certainty`, `speaker_role`, `directness`, `audience`는 2장 진실 판정 규칙의 입력(Claim 속성)으로 그대로 씁니다.

#### 판정 결과 처리 (임계값은 골든셋으로 조정)

아래 표는 초기값입니다. 현재 값과 조정 근거는 `src/lib/pipeline/judge.config.ts`에 있습니다 (자동 반영 기준 0.85 → 0.8).

| 조건 | 처리 |
|---|---|
| `is_my_commitment` ≥ 0.85, `is_actionable` ≥ 0.85, `already_done` < 0.3, `certainty=firm` | 자동 반영 |
| 위 확률 중 하나라도 0.4~0.85 구간, 또는 `certainty=tentative` | 확인 요청 목록 |
| `is_my_commitment` < 0.4 또는 `is_actionable` < 0.4 또는 `certainty=none` | 반영 안 함. 기각 로그는 남깁니다 (누락 분석용) |

기각 사유는 어느 질문의 확률이 낮았는지로 코드가 만듭니다 (`NOT_MY_ACTION`, `INFO_ONLY`, `TENTATIVE`, `ALREADY_DONE`).
Jev는 설명 문장을 주지 않으므로, 사용자에게 보여줄 이유는 이 사유 코드와 원문 인용으로 구성합니다.

#### Jev를 더 쓸 수 있는 곳

| 위치 | 질문 | 효과 |
|---|---|---|
| 추출 전 사전 필터 | `noul`: "이 메시지 조각에 약속·할당이 있는가?" | 약속 없는 잡담·공지는 비싼 LLM 추출을 건너뜀 |
| 매칭 판정 | `choice`: new / update / duplicate / complete (state에 후보와 기존 Action을 함께) | 병합 오판을 확률로 관리 |
| "지금 할 일" 랭킹 | `score`: 긴급도 척도 | 규칙 기반 정렬의 보조 신호 |

### 주의할 점

- **한국어 성능을 먼저 확인합니다.** 공개 예시는 대부분 영어입니다. 골든셋(한국어 회의록·메시지)에서 Jev 확률과 사람 라벨의 일치율, 보정 정도(예: 0.8이라고 한 것 중 실제로 80%가 맞는지)를 측정한 뒤 임계값을 정합니다. 질문 `instructions`는 영어로 쓰고 `state`는 원문 그대로 두는 방식과 둘 다 한국어로 쓰는 방식을 비교합니다.
- **Decisions API는 alpha입니다.** 요청 형식이 바뀔 수 있으니 호출은 `src/lib/ai/jev.ts` 한 파일에 감싸고, 응답은 zod로 검증합니다.
- **Judge도 틀립니다.** "Jev가 기각했는데 사실은 맞던 것"(누락 증가)을 함께 봅니다. eval에서 precision과 recall을 항상 같이 보고 Jev 적용 전후를 비교합니다.
- **사용자 피드백을 되먹임합니다.** 사용자가 삭제한 Action은 골든셋 후보로 쌓아 질문 문구와 임계값을 개선합니다 (PRD 지표 1과 직결).
- **데이터 경로**: 원문 일부가 OpenRouter와 TypeSafe를 거칩니다. 베타 테스터 동의서에 명시합니다.

---

## 2. 진실 판정 기준

### Claim 단위로 저장

Action의 각 필드(기한, 범위, 담당, 상태)에 대한 발언을 Claim으로 따로 저장합니다.
Action의 현재 값은 Claim들로부터 **계산되는 값**입니다.

```
Claim  id, action_id, field(due|scope|owner|status), value,
       source_id, quote, occurred_at,          -- 발언 시점 (입력 시점 아님)
       speaker, speaker_role(me|counterpart|third_party),
       certainty(firm|tentative),              -- "~할게요" vs "아마 ~쯤"
       directness(first_hand|reported),        -- 본인 발언 vs "민수가 그러던데"
       audience(shared|private),               -- 상대에게 한 말 vs 내 메모
       state(active|superseded|disputed)
```

### 판정 규칙 (위에서부터 순서대로 적용)

**규칙 0. 결정권자가 누구인가 (필드별 권한)**

약속은 두 사람 사이의 합의입니다. 따라서 필드마다 값을 바꿀 권한이 있는 사람이 다릅니다.

| 필드·변경 | 유효하게 바꿀 수 있는 사람 |
|---|---|
| 기한을 **늦추기**, 범위를 **줄이기** | 요청한 쪽(counterpart). 또는 내가 제안하고 상대가 수락한 경우 |
| 기한을 **당기기**, 범위를 **늘리기** | 나 혼자서도 가능 (스스로 부담을 늘리는 것) |
| 담당 변경 | 넘기는 사람과 받는 사람 모두 확인되어야 확정 |
| 완료 처리 | 결과물 전달이 원문으로 확인될 때 ("보냈습니다", 첨부 발송 등) |

**규칙 1. 공유된 약속이 개인 메모를 이긴다**

내 메모에 "월요일에 보내자"라고 적었어도 상대에게는 "금요일"이라고 말했다면, 사실은 **금요일**입니다.
단, 이 차이는 버리지 않고 "상대는 금요일로 알고 있음" 위험 신호로 표시합니다.

**규칙 2. 확정이 추정을 이긴다**

"아마 다음 주 초쯤"은 "금요일까지 드릴게요"를 덮어쓰지 못합니다.
추정성 발언은 `tentative` Claim으로 남기고 "기한 변경 가능성" 힌트로만 보여줍니다.

**규칙 3. 직접 발언이 전해 들은 말을 이긴다**

"민수님이 월요일도 괜찮대요"(전언)는 확인 요청 목록으로 보냅니다. 민수 본인의 발언이 들어오면 그때 확정합니다.

**규칙 4. 같은 조건이면 나중 발언이 이긴다**

비교 기준은 **발언 시점**(`occurred_at`)입니다. Taskforce에 입력된 시점이 아닙니다.
어제 회의록을 오늘 붙여넣어도 그제 온 메시지보다 최신으로 취급해야 합니다.

**규칙 5. 동점일 때만 채널 신뢰도를 본다**

같은 시점, 같은 권한인데 값이 다를 때의 마지막 기준입니다.
서면 확인(메일·문서) > 채팅 메시지 > 회의록(음성인식 오류 가능성).

**규칙 6. 그래도 못 정하면 사용자에게 묻는다**

두 인용을 나란히 보여주고 한 번에 고르게 합니다.

```
기한이 엇갈립니다
  ○ 금요일 9/26 — "금요일까지 제안서 보내드릴게요" (9/22 회의록)
  ○ 월요일 9/29 — "월요일에 받아도 돼요" (9/24 Slack, 김대표)
```

### 공통 원칙

- **아무 Claim도 지우지 않습니다.** 진 Claim은 `superseded`로 남겨 Action 상세의 변경 이력에 보여줍니다.
- **판정 이유를 저장합니다.** 예: "규칙 0 + 4: 요청자가 9/24에 기한 연장 수락". 사용자가 "왜 월요일이지?"라고 물을 때 바로 답할 수 있어야 합니다.
- **판정 함수는 순수 함수입니다.** `resolve(claims) → { value, winningClaimId, rule, needsConfirmation }` 형태로 만들고, 위 규칙마다 단위 테스트를 둡니다.

### 구현

- `src/lib/pipeline/resolve.ts`: `resolveField(field, claims)` / `resolveAction(claims)`. 규칙마다 `resolve.test.ts`에 테스트가 있다.
- Claim 속성(누가 · 확정도 · 직접 · 공유)은 Jev 판정(`speaker_role`, `statement_certainty`, `directness`, `audience`)에서 온다.
- `src/lib/pipeline/merge.ts`: 새 후보를 기존 Action에 Claim으로 붙인다. 매칭(`match.ts`)은 임베딩(`EMBEDDING_MODEL`, 기본 `openai/text-embedding-3-small`)으로 비슷한 열린 Action을 5개까지 추리고 Jev에게 new / 같은 일의 반복 · 변경 · 완료 · 취소를 묻는다. 관계 확신이 0.6 미만이면 병합을 확인받는다.

### 핵심 시나리오에 적용

| 시점 | 원문 | Claim | 결과 |
|---|---|---|---|
| 9/22 | (회의) 나: "금요일까지 제안서 보내드릴게요" | due=금, me, firm, shared | 기한 금요일 |
| 9/23 | (내 메모) "제안서 월요일에 보내도 될 듯" | due=월, me, tentative, private | 금요일 유지 (규칙 1, 2) + 위험 신호 |
| 9/24 | (Slack) 김대표: "월요일에 받아도 괜찮아요" | due=월, counterpart, firm, shared | **월요일로 갱신** (규칙 0: 요청자가 연장 수락) |
