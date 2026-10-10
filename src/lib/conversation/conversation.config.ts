// 대화 v2의 상한 · 기본값 (런타임 계약 12장). 값을 바꾸면 테스트를 함께 바꾼다.

/** 모델에 넣는 최근 메시지 수 (지금 메시지 포함). 그보다 앞의 메시지는 넣지 않고 넣지 않은 수를 알린다 */
export const CONVERSATION_WINDOW = 20;

/** 앞 메시지 하나를 모델에 넣을 때의 글자 상한 (지금 메시지는 자르지 않는다). 자르면 잘랐다고 표시한다 */
export const WINDOW_MESSAGE_CHARS = 1500;

/**
 * 처리 중 표시 시간 (초): 이 안에 같은 client_message_id가 다시 오면 409 in_progress(모델을 두 번 부르지 않는다).
 * 실행 한도(60초) + 여유. 서버가 죽어 표시를 풀지 못해도 이 시간이 지나면 다시 처리할 수 있다
 */
export const REPLY_LEASE_SECONDS = 75;

/** 모델에 보여 주는 열린 할 일 수 상한. 전체 수는 따로 알린다 (부분만 보이면 부분이라고 말한다, A04) */
export const OPEN_ACTIONS_SHOWN = 50;

/** 최근에 끝낸 할 일: 이 기간 · 이 수까지 */
export const DONE_RECENT_DAYS = 7;
export const DONE_RECENT_SHOWN = 20;

/** 할 일 하나에서 모델에 보내는 근거 구절 수 · 원문 발췌 길이 */
export const QUOTES_PER_ACTION = 2;
export const SOURCE_EXCERPT_CHARS = 700;
/** 원문(근거 · 조각)을 모델에 보내는 수 상한 */
export const SOURCES_SHOWN = 12;

/** 모델에 보여 주는 기억 수 상한 */
export const MEMORY_SHOWN = 40;

/** 한 번의 답에서 저장하는 기억 수 상한 */
export const MEMORY_WRITES_PER_TURN = 5;

/** 답 구간 수 · 글자 상한 (모델 출력 검사) */
export const REPLY_SEGMENTS_MAX = 12;
export const REPLY_TEXT_MAX_CHARS = 4000;

/**
 * 기억 판정(인용이 문장을 그대로 말하는가, Jev noul)의 통과 기준. 판정 자동 반영 0.8과 같은 보정 철학 (pipeline/judge.config.ts).
 * 미만이면 저장하지 않는다 (inferred로도 쓰지 않는다)
 */
export const MEMORY_SUPPORT_ACCEPT = 0.8;
