import type { Claim, ClaimField } from "./resolve";

// 구조화된 할 일 (docs/INTEGRATIONS.md "Notion 할 일 DB"): 담당 · 기한 · 상태가 이미 필드로 있는 외부 할 일.
// LLM으로 읽지 않고, 속성 스냅샷을 비교해 바뀐 필드만 Claim으로 옮긴다. 모두 순수 함수다.

export type TaskStatus = "open" | "done" | "dropped";
export type TaskOwner = "me" | "other" | "unknown";

/** 외부 할 일 한 버전의 속성. 연동 모듈(예: notion/tasks.ts)이 만든다. */
export type TaskSnapshot = {
  title: string;
  /** 담당자 표시 이름 (원문에 적는다. 이메일은 넣지 않는다) */
  assignees: string[];
  owner: TaskOwner;
  /** YYYY-MM-DD (한국 시간) */
  due: string | null;
  status: TaskStatus;
  /** 외부 서비스의 상태 이름 (예: "Current"). 근거 인용에 그대로 보여준다 */
  statusLabel: string | null;
};

const line = {
  scope: (s: TaskSnapshot) => `# ${s.title}`,
  owner: (s: TaskSnapshot) => `담당: ${s.assignees.length ? s.assignees.join(", ") : "없음"}`,
  due: (s: TaskSnapshot) => `기한: ${s.due ?? "없음"}`,
  status: (s: TaskSnapshot) => `상태: ${s.statusLabel ?? s.status}`,
} satisfies Record<ClaimField, (s: TaskSnapshot) => string>;

/** 원문(sources.raw_text)으로 저장할 글. 근거 인용은 이 글의 줄이라 기계 검증을 그대로 통과한다. */
export function renderSnapshot(s: TaskSnapshot): string {
  return [line.scope(s), line.owner(s), line.due(s), line.status(s)].join("\n");
}

const FIELD_VALUE = {
  scope: (s: TaskSnapshot) => s.title,
  owner: (s: TaskSnapshot) => s.owner,
  due: (s: TaskSnapshot) => s.due,
  status: (s: TaskSnapshot) => s.status,
} satisfies Record<ClaimField, (s: TaskSnapshot) => string | null>;

const FIELDS: ClaimField[] = ["scope", "owner", "due", "status"];

export type SnapshotChange = { field: ClaimField; value: string | null; quote: string };

/**
 * 판정에 쓰는 값(제목 · 담당 · 기한 · 상태)이 바뀐 필드. 처음 보는 할 일이면(prev 없음) 값이 있는 필드 전부.
 * 담당자 이름만 바뀌거나 상태 이름만 바뀐 것(예: Not started → Next, 둘 다 open)은 변화로 보지 않는다.
 */
export function snapshotChanges(prev: TaskSnapshot | null, next: TaskSnapshot): SnapshotChange[] {
  return FIELDS.flatMap((field) => {
    const value = FIELD_VALUE[field](next);
    if (prev ? FIELD_VALUE[field](prev) === value : value === null) return [];
    return [{ field, value, quote: line[field](next) }];
  });
}

export type TaskEdit = {
  /** 이 버전을 마지막으로 고친 사람이 사용자인가 (Notion의 last_edited_by) */
  editedByUser: boolean;
  /** 고친 시각 (규칙 4의 발언 시점) */
  occurredAt: Date;
};

/**
 * 바뀐 필드 → Claim. 사용자가 고쳤으면 tracker(사용자가 할 일 도구에서 직접 정한 값), 다른 사람이 고쳤으면
 * 팀 기록을 관리하는 쪽(counterpart)의 결정으로 본다. 팀이 함께 보는 기록에 직접 적은 값이라 firm · first_hand · shared.
 */
export function taskClaims(changes: SnapshotChange[], edit: TaskEdit, newId: () => string): Claim[] {
  const who = edit.editedByUser ? ({ speakerRole: "me", origin: "tracker" } as const) : ({ speakerRole: "counterpart", origin: "source" } as const);
  return changes.map(({ field, value }) => ({
    id: newId(),
    field,
    value,
    occurredAt: edit.occurredAt,
    certainty: "firm",
    directness: "first_hand",
    audience: "shared",
    channel: "task",
    ...who,
  }));
}

/** 판정에 쓰는 값이 같으면 새 원문을 남기지 않는다 (본문 편집 · 댓글 같은 잡음). */
export function sameForClaims(a: TaskSnapshot, b: TaskSnapshot): boolean {
  return FIELDS.every((field) => FIELD_VALUE[field](a) === FIELD_VALUE[field](b));
}
