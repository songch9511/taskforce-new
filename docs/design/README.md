# 0.2.0 설계 문서

에이전트 게이트웨이 · Mac bridge · Assistant를 구현하는 PR은 이 폴더의 문서를 기준으로 한다. 규칙이 겹치면 위 문서가 이긴다.

1. [Assistant 계약](taskforce-0.2.0-assistant-contract-2026-10-12.md) (v3, 2026-10-13) — 대화 대상 · 칩 · 에이전트 직접 대화 · 질문 · 중단 · 세션 · 프로젝트 · 이슈 번호, adapter 실행 계약(13장), 검증 기준 AC-1–AC-42.
2. [런타임 계약](taskforce-0.2.0-runtime-contract.md) — 객체 소유권, 실행 run · step, adapter capability · 사건 봉투 · `agent_tasks` 전이, 결정 라우팅, 기본값표.
3. [아키텍처](taskforce-0.2.0-architecture-fable-2026-10-09.md) — 맥락층 · 코디네이터 · 게이트웨이 · bridge의 배경과 근거. 8.2의 spawn 계약은 Assistant 계약 13장이 고친다(환경변수 목록 · setting sources · 질문 · 승인 통로).
4. 프로젝트 세션 구조(하위 에이전트 트리, 2026-10-23) — [구현 계획](taskforce-0.2.0-agent-tree-implementation-plan-2026-10-23.md)(PR T1 · T2 · T3s · T3m) ← [실측](taskforce-0.2.0-agent-tree-observation-2026-10-23.md)(Claude 2.1.306 · Codex 0.162.1, 사용자 확정 범위) ← [조사](taskforce-0.2.0-agent-tree-research-2026-10-23.md). 실측 · 계획이 조사보다 이기고, 겹치면 Assistant 계약이 이긴다(T2가 13장을 고친다).

문서 안의 `.omx/plans/…` 링크와 `~/.claude/worktrees/…` 경로는 코디네이터 로컬 파일이다(저장소 밖). 구현 순서 · PR 단위 · 완료 기준은 코디네이터가 WP마다 `handoffs/<wp>-contract.md`로 넘긴다.
