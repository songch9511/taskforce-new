-- 원문 처리 상태 (Phase 1: POST /api/v1/sources가 202를 돌려준 뒤 파이프라인을 백그라운드로 돌린다)
-- 앱과 /lab은 이 값을 보고 처리가 끝났는지 안다. 결과 후보는 judge_logs에 남는다.

alter table public.sources
  add column processing_status text not null default 'pending'
    check (processing_status in ('pending', 'processing', 'done', 'failed')),
  add column processed_at timestamptz,
  -- 단계별 개수 · 모델 · 프롬프트 버전 · 비용. 원문이나 인용은 넣지 않는다.
  add column processing_summary jsonb,
  -- 사용자에게 보여줄 짧은 실패 사유. 원문을 담지 않는다.
  add column processing_error text;
