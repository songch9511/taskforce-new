-- 직접 추가한 Action · 내가 쓴 문서 표시.

-- 1) ActionEvent 종류: 사용자가 원문 없이(또는 원문을 골라) 직접 추가한 Action (actor user, after: { source_id })
--    필드 값은 origin 'user' Claim에서 계산한다. 추출이 놓친 할 일이라는 신호이므로 지표 4의 분자로 센다.
alter table public.action_events drop constraint action_events_type_check;
alter table public.action_events add constraint action_events_type_check check (type in (
  'created', 'due_changed', 'scope_changed', 'owner_changed', 'merged', 'completed', 'dropped', 'reopened',
  'user_edited', 'user_deleted', 'user_confirmed', 'user_started', 'user_reported_missing', 'user_created'
));

-- 2) 원문을 사용자가 직접 썼나 (예: Notion 문서의 작성자 = 연결한 사용자). 모르면 null.
--    판정(Jev)이 "내 문서에 적은 할 일 = 내가 정한 할 일"로 볼 수 있게 넘긴다 (docs/TRUTH_RULES.md 1장).
alter table public.sources add column written_by_me boolean;
