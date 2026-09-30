-- 회의 원문(Notion 회의록 · Meet 전사)에 붙인 Calendar 일정 (docs/go-live/google-integration.md 2-7).
-- { calendar_event_id, title, start, end }: 앱이 근거 줄에 "Sep 30 · Proposal review — Acme"를 보이고 Sources를 한 회의로 묶는 데 쓴다.
-- 일정 자체는 저장하지 않는다(설명 · 첨부 · 참석자 목록 없음). 참석자는 기존 participants.attendees로 들어간다.
-- 새 표가 아니라 기존 sources 열이므로 RLS(owner_all)와 (id, user_id) 복합 외래키를 그대로 따른다.
-- 원문 행과 함께 지워진다(계정 삭제). 90일 본문 삭제(purge_expired_source_text)는 raw_text만 비우므로 이 열은 남는다(제목 · 관련자와 같은 취급).

alter table public.sources add column meeting jsonb;

-- 모양 확인. 없는 키는 jsonb_typeof가 null이라 check가 통과해 버리므로 coalesce로 false를 만든다.
alter table public.sources add constraint sources_meeting_shape check (
  meeting is null
  or (
    coalesce(jsonb_typeof(meeting) = 'object', false)
    and coalesce(jsonb_typeof(meeting->'calendar_event_id') = 'string', false)
    and coalesce(jsonb_typeof(meeting->'start') = 'string', false)
    and coalesce(jsonb_typeof(meeting->'end') = 'string', false)
    and coalesce(jsonb_typeof(meeting->'title') in ('string', 'null'), true)
  )
);
