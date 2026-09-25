# Taskforce 시스템 아키텍처

관련 문서: [PRD](PRD.md) · [오탐 방지와 진실 판정 기준](TRUTH_RULES.md) · [바이브코딩 플랜](VIBE_CODING_PLAN.md)

1. [전체 구성도](#1-전체-구성도)
2. [처리 파이프라인](#2-처리-파이프라인)
3. [진실 판정 흐름](#3-진실-판정-흐름)
4. [핵심 시나리오: 금요일 → 월요일](#4-핵심-시나리오-금요일--월요일)
5. [데이터 모델](#5-데이터-모델)
6. [사용자 흐름과 학습 루프](#6-사용자-흐름과-학습-루프)

---

## 1. 전체 구성도

```mermaid
flowchart LR
    subgraph IN["입력 소스"]
        direction TB
        P["붙여넣기 / 업로드<br/>(MVP)"]
        G["Gmail"]
        C["캘린더·회의록<br/>(Notion, Meet 등)"]
        S["Slack"]
    end

    subgraph APP["Taskforce (Next.js on Vercel)"]
        direction TB
        UI["웹 UI<br/>지금 할 일 · 확인 요청 · Action 상세"]
        API["서버 API<br/>(Route Handlers / Server Actions)"]
        ADP["소스 어댑터<br/>원문 → Source로 정규화"]
        Q["작업 큐<br/>(비동기 파이프라인 실행)"]
        PIPE["처리 파이프라인<br/>src/lib/pipeline"]
        RES["진실 판정 resolve()<br/>순수 함수 · 규칙 기반"]
        MCP["MCP 서버<br/>AI 핸드오프"]
    end

    subgraph DB["Supabase"]
        direction TB
        AUTH["Auth"]
        PG[("Postgres<br/>Source · Action · Claim<br/>Evidence · Event")]
        VEC[("pgvector<br/>Action 임베딩")]
    end

    subgraph OR["OpenRouter (API 키 1개)"]
        direction TB
        LLM["생성형 LLM<br/>chat completions<br/>Claim 추출"]
        JEV["Jev<br/>Decisions API<br/>검증 · 분류 · 매칭 판정"]
        EMB["임베딩 모델"]
    end

    EXT["외부 AI 도구<br/>(Claude 등)"]

    P --> UI
    G & C & S --> ADP
    UI <--> API
    API --> ADP
    ADP --> Q --> PIPE
    PIPE <--> LLM
    PIPE <--> JEV
    PIPE <--> EMB
    PIPE <--> VEC
    PIPE --> RES --> PG
    API <--> PG
    API <--> AUTH
    MCP <--> PG
    EXT <--> MCP
```

| 구성 요소 | 역할 | 비고 |
|---|---|---|
| 소스 어댑터 | 채널별 원문을 공통 `Source`(원문, 발언 시점, 출처 링크)로 변환 | 연동이 늘어도 파이프라인은 그대로 |
| 작업 큐 | 입력을 받자마자 응답하고, 추출은 백그라운드에서 실행 | 예: Inngest, Supabase Queues |
| 처리 파이프라인 | 추출 → 검증 → 매칭 → Claim 저장 | UI·DB와 분리된 순수 함수라 eval에서 그대로 실행 |
| resolve() | Claim들로부터 Action의 현재 값을 계산 | LLM 없음, 단위 테스트로 고정 |
| MCP 서버 | 외부 AI가 "내 Action과 맥락"을 조회 | 4단계 이후 |

---

## 2. 처리 파이프라인

원문 하나가 들어와서 "지금 할 일"에 반영되기까지의 흐름입니다.

```mermaid
flowchart TD
    A([Source 입력]) --> F{"① 사전 필터 · Jev noul<br/>약속·할당이 있는가?"}
    F -- "P < 0.2" --> SKIP([건너뜀<br/>잡담·공지])
    F -- "P ≥ 0.2" --> X["② Claim 추출 · 생성형 LLM<br/>제목 · 인용 · 날짜 표현 · 발언자"]

    X --> M{"③ 기계적 검증 · 코드<br/>인용이 원문에 있나?<br/>날짜 재계산 일치?<br/>스키마 통과?"}
    M -- 실패 --> DROP1([폐기 · 환각])
    M -- 통과 --> J{"④ Jev 검증<br/>내 약속? 실제 행동?<br/>이미 완료? 확정도?"}

    J -- "낮음 (< 0.4)" --> DROP2([기각 · 로그만 남김<br/>누락 분석용])
    J -- "애매함 (0.4 ~ 0.85)" --> CQ[[확인 요청 목록]]
    J -- "높음 (≥ 0.85)" --> K["⑤ 후보 매칭<br/>임베딩으로 열린 Action top-5 검색"]
    CQ -- 사용자 확정 --> K

    K --> MJ{"⑥ Jev 매칭 판정 · choice"}
    MJ -- new --> NEW["새 Action 생성"]
    MJ -- "update / complete" --> CL["기존 Action에<br/>Claim 추가"]
    MJ -- duplicate --> EV["근거(Evidence)만 추가"]
    MJ -- 애매함 --> CQ

    NEW --> CL
    CL --> R["⑦ resolve() · 진실 판정<br/>규칙 0~6 적용"]
    R -- 판정 불가 --> CQ
    R -- 판정됨 --> ACT[("Action 현재 값 갱신<br/>+ ActionEvent 기록")]
    EV --> ACT
    ACT --> RANK["⑧ 지금 할 일 랭킹<br/>기한 임박 · 외부 약속 · 방치 기간"]
    RANK --> NOW([지금 할 일 화면])
```

| 단계 | 누가 | 입력 → 출력 |
|---|---|---|
| ① 사전 필터 | Jev `noul` | 메시지 조각 → 약속이 있을 확률. 낮으면 비싼 추출을 건너뜀 |
| ② 추출 | 생성형 LLM | 원문 → Claim 후보 목록 (구조화 출력) |
| ③ 기계적 검증 | 코드 | 인용 실재·날짜·스키마 확인. 환각 제거 |
| ④ 검증 | Jev `noul` + `choice` | 후보 → 확률 + Claim 속성(확정도, 발언자, 직접성, 공개 여부) |
| ⑤ 매칭 | pgvector | 후보 → 비슷한 열린 Action top-5 |
| ⑥ 매칭 판정 | Jev `choice` | 후보 + 기존 Action → new / update / duplicate / complete |
| ⑦ 진실 판정 | 코드 `resolve()` | Claim 목록 → 필드 값 + 적용 규칙 |
| ⑧ 랭킹 | 코드 (+ Jev `score` 보조) | 열린 Action → 지금 할 일 순서 |

확률 기준(0.2, 0.4, 0.85)은 출발값입니다. 한국어 골든셋으로 측정한 뒤 조정합니다.

---

## 3. 진실 판정 흐름

같은 Action의 같은 필드(예: 기한)에 대해 서로 다른 Claim이 있을 때 `resolve()`가 따르는 순서입니다.
규칙 상세는 [TRUTH_RULES.md 2장](TRUTH_RULES.md#2-진실-판정-기준)을 보세요.

```mermaid
flowchart TD
    S([같은 필드에 대한<br/>상충하는 Claim들]) --> R0{"규칙 0<br/>바꿀 권한이 있는<br/>사람의 발언인가?"}
    R0 -- "권한 없음<br/>(예: 내가 혼자 기한 연장)" --> DIS["후보에서 제외<br/>위험 신호 표시"]
    R0 -- 권한 있음 --> R1{"규칙 1<br/>상대에게 한 말인가,<br/>내 메모인가?"}
    R1 -- 내 메모만 --> DIS
    R1 -- 상대에게 공유됨 --> R2{"규칙 2<br/>확정인가, 추정인가?"}
    R2 -- 추정 --> HINT["힌트로만 표시<br/>(기한 변경 가능성)"]
    R2 -- 확정 --> R3{"규칙 3<br/>본인 발언인가,<br/>전해 들은 말인가?"}
    R3 -- 전언 --> ASK
    R3 -- 본인 발언 --> R4{"규칙 4<br/>남은 후보 중<br/>발언 시점이 가장 늦은 것?"}
    R4 -- 하나로 정해짐 --> WIN
    R4 -- 같은 시점 동점 --> R5{"규칙 5<br/>채널 신뢰도<br/>메일·문서 > 채팅 > 회의록"}
    R5 -- 정해짐 --> WIN(["채택<br/>진 Claim은 superseded로 보관<br/>적용 규칙 기록"])
    R5 -- 그래도 동점 --> ASK[["규칙 6<br/>두 인용을 나란히 보여주고<br/>사용자에게 확인"]]
```

---

## 4. 핵심 시나리오: 금요일 → 월요일

```mermaid
sequenceDiagram
    autonumber
    actor U as 사용자
    participant T as Taskforce
    participant L as 생성형 LLM
    participant J as Jev
    participant R as resolve()
    participant D as DB

    Note over U,D: 9/22 회의
    U->>T: 회의록 붙여넣기<br/>"금요일까지 제안서 보내드릴게요"
    T->>L: Claim 추출
    L-->>T: 제안서 발송 · due=금 · 발언자=나
    T->>J: 검증 질문
    J-->>T: 내 약속 0.97 · firm · shared
    T->>J: 매칭 판정 (열린 Action 없음)
    J-->>T: new
    T->>R: Claim [금 · me · firm · shared]
    R-->>D: Action 생성 · 기한 금요일

    Note over U,D: 9/23 내 메모
    U->>T: "제안서 월요일에 보내도 될 듯"
    T->>J: 검증 + 매칭
    J-->>T: tentative · private · update
    T->>R: Claim 추가 [월 · me · tentative · private]
    R-->>D: 금요일 유지 (규칙 1, 2) + 위험 신호

    Note over U,D: 9/24 Slack
    U->>T: 김대표 "월요일에 받아도 괜찮아요"
    T->>J: 검증 + 매칭
    J-->>T: firm · counterpart · shared · update
    T->>R: Claim 추가 [월 · counterpart · firm · shared]
    R-->>D: 기한 월요일로 갱신 (규칙 0: 요청자가 연장 수락)

    Note over U,D: 9/29 월요일 아침
    U->>T: 앱 열기
    T-->>U: 지금 할 일 1순위 "제안서 발송"<br/>합의 범위 + 회의록·Slack 인용
    U->>T: AI에게 넘기기
    T-->>U: 맥락이 담긴 핸드오프 문서
```

---

## 5. 데이터 모델

```mermaid
erDiagram
    USER ||--o{ SOURCE : "입력"
    USER ||--o{ ACTION : "소유"
    SOURCE ||--o{ CLAIM : "발언 추출"
    SOURCE ||--o{ EVIDENCE : "인용 제공"
    ACTION ||--o{ CLAIM : "필드별 주장"
    ACTION ||--o{ EVIDENCE : "근거"
    ACTION ||--o{ ACTION_EVENT : "변경 이력"
    USER ||--o{ METRIC_EVENT : "행동 기록"
    SOURCE ||--o{ JUDGE_LOG : "판정 기록"

    SOURCE {
        uuid id
        text kind "meeting | message | email | doc"
        text raw_text
        timestamptz occurred_at "발언 시점"
        text external_url
    }
    ACTION {
        uuid id
        text title
        text scope_summary
        text owner "resolve 결과"
        timestamptz due_at "resolve 결과"
        text status "open | done | dropped"
        bool needs_confirmation
        vector embedding
    }
    CLAIM {
        uuid id
        text field "due | scope | owner | status"
        text value
        text quote
        timestamptz occurred_at
        text speaker_role "me | counterpart | third_party"
        text certainty "firm | tentative"
        text directness "first_hand | reported"
        text audience "shared | private"
        text state "active | superseded | disputed"
    }
    EVIDENCE {
        uuid id
        text quote
        text role "created | updated | completed"
    }
    ACTION_EVENT {
        uuid id
        text type "created | due_changed | merged | user_edited | user_deleted ..."
        jsonb before
        jsonb after
        text actor "ai | user"
        text rule "적용된 판정 규칙"
    }
    JUDGE_LOG {
        uuid id
        jsonb candidate
        jsonb jev_answers "질문별 확률"
        text decision "auto | confirm | reject"
        text model_version
    }
    METRIC_EVENT {
        uuid id
        text type "app_opened | action_started | handoff_used"
        timestamptz at
    }
```

`JUDGE_LOG`는 PRD 초안에 없던 테이블입니다. 기각한 후보도 남겨야 "Jev가 버렸는데 사실은 맞던 것"(누락)을 나중에 분석할 수 있어서 추가했습니다.

---

## 6. 사용자 흐름과 학습 루프

사용자가 무언가를 고칠 때마다 그 기록이 지표와 골든셋으로 돌아가서 판정 품질을 개선합니다.

```mermaid
flowchart LR
    subgraph USE["사용자 흐름"]
        direction TB
        O([앱 열기]) --> N["지금 할 일"]
        N --> DT["Action 상세<br/>합의 범위 · 근거 인용 · 변경 이력"]
        DT --> HO["AI에게 넘기기"]
        DT --> DONE["완료 · 착수"]
        N --> CQ["확인 요청<br/>한 번에 확정 · 수정"]
        DT --> ED["직접 수정 · 삭제"]
    end

    subgraph MEAS["측정"]
        direction TB
        M1["지표 1<br/>AI 오판율"]
        M2["지표 2<br/>착수 시간"]
        M3["지표 3<br/>리텐션"]
    end

    subgraph LEARN["개선 루프"]
        direction TB
        GS[("골든셋<br/>evals/golden")]
        EVAL["npm run eval<br/>precision · recall · 보정 표"]
        TUNE["프롬프트 · Jev 질문 문구<br/>· 확률 기준 조정"]
    end

    ED -- "user_edited / user_deleted" --> M1
    CQ -- "user_confirmed / 수정" --> M1
    O -- app_opened --> M2
    HO -- handoff_used --> M2
    DONE -- action_started --> M2
    O --> M3

    ED -- "오판 사례 (익명화)" --> GS
    CQ -- "애매했던 사례" --> GS
    GS --> EVAL --> TUNE
    TUNE -. "배포" .-> PIPE2(["처리 파이프라인"])
    M1 -- "높으면 피벗 검토" --> PIV{{"AI PM 접근 재검토"}}
```
