import Link from "next/link";
import { notFound } from "next/navigation";

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { requireUser } from "@/lib/auth";
import { bucketText, type DimCount, type LatencyGroup, type Quantiles } from "@/lib/metrics/agents";
import { HOLD_REASONS, RUN_STATES, type ErrorField, type HoldReason, type MissedMetric, type RunState } from "@/lib/metrics/compute";
import { isAdmin, loadMetrics } from "@/lib/metrics/load";
import { createAdminClient } from "@/lib/supabase/admin";

// 관리자용 지표 (PRD 6장). 모든 사용자의 이벤트를 모아 숫자만 보여준다 — 원문 · 할 일 제목은 보여주지 않는다.
// ADMIN_EMAILS에 없는 사용자에게는 없는 페이지처럼 보인다.

const PERIODS = [7, 28, 90] as const;
const FIELD_LABELS: Record<ErrorField, string> = { title: "내용", due: "기한", owner: "담당", status: "상태", deleted: "삭제", duplicate: "중복(병합)" };
const MISS_STAGE_LABELS: Record<keyof MissedMetric["byStage"], string> = {
  not_extracted: "추출 안 됨 (검증 탈락 포함)",
  quoted_history: "연결 메일의 인용된 옛 메일 속이라 버림",
  judge_rejected: "Jev가 기각",
  merge_absorbed: "병합에서 다른 Action에 합쳐짐",
  processing_failed: "원문 처리 실패 · 미완료",
  unknown: "단계 기록 없음",
};

const RUN_STATE_LABELS: Record<RunState, string> = {
  queued: "대기",
  running: "진행",
  waiting_approval: "승인 대기",
  done: "끝",
  failed: "실패",
  stopped: "멈춤",
};
const HOLD_LABELS: Record<HoldReason, string> = {
  blocked: "차단 스위치 · 도구 · 수신자 · 서버 쪽 보류",
  actor: "실행 주체 목록 밖",
  needs_connection: "보내는 연결 없음",
  credit: "크레딧 부족",
};

/** 에이전트 카드 (OA I-oa): 이벤트 type · 차원 · 상태 이름. 값은 서버가 남긴 토큰이라 모르는 값은 그대로 보인다 */
const AGENT_TYPE_LABELS: Record<string, string> = {
  agent_message_sent: "에이전트에게 전달 시작 (대기열 · 재전달 · Mac 복귀 포함)",
  context_attached: "맥락 붙임",
  stop_requested: "Stop",
  message_resent: "다시 보냄",
  question_answered: "질문에 답함 (카드 · 승인 · 비밀값 로컬 답)",
  session_renamed: "세션 이름 바꿈",
  session_opened_external: "터미널에서 열기",
  session_resumed: "여기서 이어가기",
  tool_call_decided: "도구 호출 결정 (서버 결정만)",
  path_conflict_found: "경로 충돌 발견",
  path_conflict_resolved: "경로 충돌 해소",
  issue_moved: "이슈 이동",
  project_created: "프로젝트 만듦",
  project_renamed: "프로젝트 이름 바꿈",
  project_icon_changed: "프로젝트 아이콘 바꿈",
  project_archived: "프로젝트 보관",
  assistant_opened: "Assistant 열기 (아직 남기는 곳 없음)",
  external_sessions_shown: "외부 세션 목록(On this Mac) 보임 (하루 한 번)",
  session_attached: "외부 세션 이어받기 (Resume here 성공)",
  claude_app_message_sent: "Claude 데스크톱 세션으로 글 보냄 (받음 · 못 보냄)",
  claude_app_chat_deleted: "저장된 Claude 데스크톱 대화 지움",
};
const AGENT_DIM_LABELS: Record<string, string> = {
  kind: "종류",
  answered_locally: "로컬 답",
  decision: "결정",
  result: "결과",
  reason: "이유",
  from: "원래 상태",
  surface: "화면",
  via: "경로",
  keep: "남긴 쪽",
  target_kind: "대상",
  origin: "출처",
  sent: "외부로 보냄",
};
const LATENCY_KIND_LABELS = { message: "메시지 (새 턴)", answer: "질문 답", cancel: "취소" } as const;
const DELIVERY_STATE_LABELS: Record<string, string> = { queued: "대기열", dispatched: "전달됨", not_sent: "못 보냄", expired: "만료", cancelled: "취소" };
const DELIVERY_REASON_LABELS: Record<string, string> = {
  expired_before_lease: "lease 전 만료 (회수)",
  expired_queue: "대기열 만료 (sweep)",
};
const COMMAND_OUTCOME_LABELS: Record<string, string> = {
  sent: "보냄",
  task_unknown: "작업을 모름",
  received: "받음",
  not_received: "받지 못함",
  unknown: "결과 불명",
  request_closed: "표시 뒤 요청이 닫혀 답이 닫힘",
  declined: "거절",
  withdrawn: "회수",
};
const QUESTION_PATH_LABELS = {
  route: "카드 · 승인 (질문 답 route)",
  message: "대화 자유 글",
  local: "비밀값 · 이 Mac에서",
  unanswered_open: "답 없음 · 지금 열림",
  unanswered_closed: "답 없음 · 닫힘 (Stop · Done · 턴 끝)",
} as const;
const STOP_GATE_LABELS = { stop: "Stop 버튼", action_closed: "이슈 Done", path_conflict: "경로 충돌로 멈춤", session_deleted: "세션 삭제", other: "기타" } as const;

const PROVIDER_LABELS: Record<string, string> = {
  notion: "Notion",
  google: "Google",
  gmail: "Gmail",
  slack: "Slack",
  microsoft: "Microsoft 365",
  zoom: "Zoom",
  github: "GitHub",
  linear: "Linear",
  jira: "Jira",
};
/** Gmail 거르기 이유 코드 (lib/connectors/gmail/filter.ts, google-integration.md 2-6 거르기 규칙 번호) */
const GMAIL_COUNT_LABELS: [string, string][] = [
  ["ingested", "새 원문"],
  ["sent", "남김 · 보낸 메일 (③)"],
  ["inbound", "남김 · 받은 메일 (⑨)"],
  ["excluded_label", "① 임시 보관 · 스팸 · 휴지통 · 채팅"],
  ["auto_submitted", "② 자동 발송"],
  ["category", "④ 프로모션 · 소셜"],
  ["bulk", "⑤ 대량 발송"],
  ["mailing_list", "⑥ 수신 거부 · 메일링 리스트"],
  ["no_reply", "⑦ no-reply 주소"],
  ["calendar", "⑧ 일정 초대"],
];

/** Google(Calendar · Meet) 연결 개수 (lib/connectors/google, google-integration.md 2-5 · 8장). 글자 · 주소 없이 개수만 쌓는다 */
const GOOGLE_COUNT_LABELS: [string, string][] = [
  ["meet_transcripts", "Meet 전사 (새 원문)"],
  ["meet_transcripts_attended", "  그중 참석한 회의만 목록으로 찾은 것 (G2 ②)"],
  ["meet_transcripts_abandoned", "포기한 전사 (2시간 넘게 파일 없음)"],
  ["meet_transcripts_short", "넣지 않은 전사 (항목 없음 · 너무 짧음)"],
  ["meet_transcripts_failed", "읽지 못해 포기한 전사 (반복된 서버 오류 · 400번대)"],
  ["meet_attended_codes", "참석한 회의 코드 조회를 마친 일정"],
  ["meet_attended_denied", "  그중 회의 기록을 못 봄 (403 · 404)"],
  ["meet_attended_failed", "참석한 회의 찾기 실패 (일정 목록은 동기화마다 · 코드 조회는 일정마다)"],
  ["meet_artifacts_denied", "전사 목록 · 항목을 못 봄 (403 · 404)"],
  ["meet_link_attached", "Meet 전사 ↔ 일정: 붙음"],
  ["meet_link_ambiguous", "Meet 전사 ↔ 일정: 애매"],
  ["meet_link_none", "Meet 전사 ↔ 일정: 없음"],
  ["meet_link_failed", "Meet 전사 ↔ 일정: 조회 실패"],
  ["notion_link_attached", "Notion 회의록 ↔ 일정: 붙음"],
  ["notion_link_ambiguous", "Notion 회의록 ↔ 일정: 애매"],
  ["notion_link_none", "Notion 회의록 ↔ 일정: 없음"],
  ["notion_link_failed", "Notion 회의록 ↔ 일정: 조회 실패"],
];

const pct = (value: number | null) => (value === null ? "—" : `${Math.round(value * 1000) / 10}%`);
const num = (value: number | null, unit = "") => (value === null ? "—" : `${Math.round(value * 10) / 10}${unit}`);
const usd = (value: number, digits = 3) => value.toFixed(digits);
const secs = (value: number | null) => (value === null ? "—" : `${Math.round(value * 10) / 10}초`);
const tallyText = (values: DimCount[]) => values.map((v) => `${v.value} ${v.n}`).join(" · ");
const quantileText = (q: Quantiles) => (q.n === 0 ? "표본 없음" : `표본 ${q.n} · p50 ${secs(q.p50)} · p95 ${secs(q.p95)} · 최대 ${secs(q.max)}`);
const ageText = (seconds: number | null) => {
  if (seconds === null) return "—";
  if (seconds < 60) return `${Math.round(seconds)}초`;
  if (seconds < 3600) return `${Math.round(seconds / 60)}분`;
  if (seconds < 86_400) return `${Math.round(seconds / 3600)}시간`;
  return `${Math.round(seconds / 86_400)}일`;
};

export default async function MetricsPage({ searchParams }: { searchParams: Promise<{ days?: string }> }) {
  const user = await requireUser();
  if (!isAdmin(user.email)) notFound();

  const { days: daysParam } = await searchParams;
  const days = PERIODS.find((d) => String(d) === daysParam) ?? 28;
  const to = new Date();
  const report = await loadMetrics(createAdminClient(), { from: new Date(to.getTime() - days * 86_400_000), to });
  const {
    misjudgment: m,
    start,
    retention,
    missed,
    shadowList: shadow,
    connections,
    gmail,
    google,
    meetingLinkage: linkage,
    discoveryCost: cost,
    sourceFailures: failures,
    execution,
    agents,
  } = report;
  // 피벗 판단은 자동 반영이 틀린 비율로 한다 (PRD 6장). 구분이 생기기 전 기록뿐이면 전체 비율을 보여준다.
  const auto = m.byConfirmation.auto;
  const headline = auto.created > 0 ? { label: "자동 반영", rate: auto.corrected / auto.created } : { label: "전체 · 구분 전 기록 포함", rate: m.rate };

  return (
    <main className="mx-auto flex max-w-4xl flex-col gap-6 p-6">
      <div className="flex flex-wrap items-baseline justify-between gap-3">
        <h1 className="text-2xl font-semibold">지표</h1>
        <nav className="flex gap-3 text-sm">
          {PERIODS.map((d) => (
            <Link key={d} href={`/admin/metrics?days=${d}`} className={d === days ? "font-semibold underline" : "text-muted-foreground hover:underline"}>
              최근 {d}일
            </Link>
          ))}
        </nav>
      </div>
      <p className="text-muted-foreground text-sm">
        PRD 6장. 기간은 Action이 만들어진 때 · 앱을 연 때 기준입니다.
        {report.excludedTestActions > 0 && ` 시험용 원문에서 나온 Action ${report.excludedTestActions}개는 뺐습니다.`}
      </p>

      <Card>
        <CardHeader>
          <CardTitle>
            1. AI 오판율 {pct(headline.rate)} <span className="text-muted-foreground text-sm font-normal">({headline.label})</span>
          </CardTitle>
          <CardDescription>
            AI가 원문에서 만든 Action {m.aiCreated}개 중 사용자가 고치거나 지우거나 다른 이슈에 병합한 것 {m.corrected}개 (전체 {pct(m.rate)}). 완료 처리는 오판이 아닙니다. 할 일 DB에서 가져온 {m.imported}개는
            AI 판단이 아니라서 뺐습니다.
          </CardDescription>
        </CardHeader>
        <CardContent className="grid gap-4 text-sm sm:grid-cols-2">
          <div>
            <h3 className="mb-1 font-medium">필드별</h3>
            <ul className="space-y-0.5">
              {(Object.keys(FIELD_LABELS) as ErrorField[]).map((f) => (
                <li key={f} className="flex justify-between">
                  <span>{FIELD_LABELS[f]}</span>
                  <span>
                    {m.byField[f]}개 · {pct(m.aiCreated ? m.byField[f] / m.aiCreated : null)}
                  </span>
                </li>
              ))}
            </ul>
          </div>
          <div>
            <h3 className="mb-1 font-medium">단계별</h3>
            <ul className="space-y-0.5">
              <li className="flex justify-between">
                <span>추출 (처음 만들 때 틀림 · 지움)</span>
                <span>{m.byStage.extract}개</span>
              </li>
              <li className="flex justify-between">
                <span>매칭 · 갱신 (나중 원문으로 바뀐 값이 틀림)</span>
                <span>{m.byStage.update}개</span>
              </li>
            </ul>
            <p className="text-muted-foreground mt-2">확인 요청에 &quot;맞아요&quot; {m.confirmed}번 (오판 아님, 확인 부담)</p>
          </div>
          <div className="sm:col-span-2">
            <h3 className="mb-1 font-medium">만들 때 바로 반영했나, 물어봤나</h3>
            <ul className="space-y-0.5">
              {(
                [
                  ["auto", "자동 반영 (틀리면 진짜 오판)"],
                  ["asked", "확인 요청 (\"아니에요\"는 설계대로 물어본 것)"],
                  ["unknown", "구분 전 기록"],
                ] as const
              ).map(([key, label]) => (
                <li key={key} className="flex justify-between">
                  <span>{label}</span>
                  <span>
                    {m.byConfirmation[key].corrected} / {m.byConfirmation[key].created}개 ·{" "}
                    {pct(m.byConfirmation[key].created ? m.byConfirmation[key].corrected / m.byConfirmation[key].created : null)}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>2. 착수 시간 {num(start.medianMinutes, "분")}</CardTitle>
          <CardDescription>
            앱을 연 뒤 한 시간 안에 첫 착수(시작 · AI에게 넘기기)까지 걸린 시간의 중앙값. 앱 열기 {start.opens}번 중 {pct(start.startedRate)}가 착수로 이어짐.
          </CardDescription>
        </CardHeader>
        {start.opens === 0 && (
          <CardContent className="text-muted-foreground text-sm">아직 앱 열기(app_opened) 기록이 없습니다. Apple 앱(Phase A1)이 보내기 시작하면 채워집니다.</CardContent>
        )}
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>3. 리텐션</CardTitle>
          <CardDescription>
            처음 활동한 주부터 N주 뒤에도 활동한 사용자 비율 (활동: 앱 열기 · 착수 · 수정 · 확인, 한국 시간 월요일 기준 주). 진행 중인 이번 주는 N주 뒤 판단에서 뺍니다.
            사용자 {retention.cohortSize}명.
          </CardDescription>
        </CardHeader>
        <CardContent className="grid gap-4 text-sm sm:grid-cols-2">
          <ul className="space-y-0.5">
            {retention.retention.map((rate, n) => (
              <li key={n} className="flex justify-between">
                <span>{n === 0 ? "첫 주" : `${n}주 뒤`}</span>
                <span>{pct(rate)}</span>
              </li>
            ))}
          </ul>
          <ul className="space-y-0.5">
            {retention.weeklyActive.slice(-6).map((w) => (
              <li key={w.week} className="flex justify-between">
                <span>{w.week} 주</span>
                <span>{w.users}명 활동</span>
              </li>
            ))}
          </ul>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>4. AI 누락률 {missed.available ? pct(missed.rate) : "측정 전"}</CardTitle>
          <CardDescription>
            (신고된 누락 {missed.reported}개 + 원문 구절을 고른 직접 추가 {missed.added}개) / (AI 생성 {m.aiCreated}개 + 신고된 누락 + 구절을 고른 직접
            추가). 사용자가 알려준 것만 세므로 실제 누락의 하한입니다. 이미 있던 할 일로 합쳐진 신고는 세지 않고, 신고 · 직접 추가로 생긴 Action은 지표
            1에서 뺐습니다. 구절 없는 직접 추가 {missed.addedPlain}개는 일반 입력이라 넣지 않았습니다.
          </CardDescription>
        </CardHeader>
        <CardContent className="text-sm">
          <h3 className="mb-1 font-medium">원래 처리에서 놓친 단계</h3>
          <ul className="space-y-0.5">
            {(Object.keys(MISS_STAGE_LABELS) as (keyof MissedMetric["byStage"])[]).map((stage) => (
              <li key={stage} className="flex justify-between">
                <span>{MISS_STAGE_LABELS[stage]}</span>
                <span>{missed.byStage[stage]}개</span>
              </li>
            ))}
          </ul>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>5. 그림자 목록 비율 {pct(shadow.rate)}</CardTitle>
          <CardDescription>
            주간 질문 &quot;Taskforce 밖에 따로 적어둔 할 일이 있나요?&quot;에 &quot;있어요&quot; / (&quot;있어요&quot; + &quot;없어요&quot;). 낮을수록 Taskforce 하나로 충분하다는
            뜻입니다. 응답 {shadow.responses}번 (있어요 {shadow.yes} · 없어요 {shadow.no} · 건너뜀 {shadow.skipped}).
          </CardDescription>
        </CardHeader>
        {shadow.responses === 0 && (
          <CardContent className="text-muted-foreground text-sm">아직 응답이 없습니다. 첫 원문을 넣고 7일이 지난 사용자에게 Apple 앱이 주마다 묻습니다.</CardContent>
        )}
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>발견 원가 ${usd(cost.totalUsd)}</CardTitle>
          <CardDescription>
            기간 안에 처리를 마친 원문 {cost.sources}개의 AI 원가 (추출 + 판정, 사용자에게 청구하지 않음). 매칭 · 임베딩 · 실패한 시도의 원가는 빠져 있어 실제보다
            적습니다. 시험용 원문([E2E 테스트])도 같은 키 한도를 쓰므로 원가 · 실패 수에 들어 있습니다. 날짜는 UTC (운영 키 하루 한도가 UTC 0시에 풀립니다).
            더 다시 처리하지 않기로 실패로 닫은 원문 {failures.closed}개
            {failures.byProvider.length > 0 && ` (${failures.byProvider.map((f) => `${PROVIDER_LABELS[f.provider] ?? (f.provider === "direct" ? "직접 넣음" : f.provider)} ${f.count}`).join(" · ")})`}.
          </CardDescription>
        </CardHeader>
        {cost.days.length > 0 && (
          <CardContent className="text-sm">
            <ul className="space-y-0.5">
              {cost.days.slice(-14).map((d) => (
                <li key={d.day} className="flex justify-between">
                  <span>{d.day}</span>
                  <span>
                    ${usd(d.usd)} · 원문 {d.sources}개
                  </span>
                </li>
              ))}
            </ul>
          </CardContent>
        )}
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>실행 (U2)</CardTitle>
          <CardDescription>
            {execution
              ? `최근 ${days}일에 만든 run ${execution.runs}개의 지금 상태. 결과 불명 단계는 지금 수(기간과 상관없이), 승인 요청 · 막힘은 기간 안에 생긴 수입니다.`
              : "실행 표를 읽지 못했습니다 (마이그레이션 20261021 · 20261022 적용 전이거나 읽기 오류, 서버 로그)."}
          </CardDescription>
        </CardHeader>
        {execution && (
          <CardContent className="grid gap-4 text-sm sm:grid-cols-2">
            <ul className="space-y-0.5">
              {RUN_STATES.map((state) => (
                <li key={state} className="flex justify-between">
                  <span>{RUN_STATE_LABELS[state]}</span>
                  <span>{execution.byState[state]}개</span>
                </li>
              ))}
            </ul>
            <ul className="space-y-0.5">
              <li className="flex justify-between">
                <span>결과 불명 단계</span>
                <span>{execution.unknownOutcome}개</span>
              </li>
              <li className="flex justify-between">
                <span>승인 요청</span>
                <span>{execution.approvalRequests}번</span>
              </li>
              {HOLD_REASONS.map((reason) => (
                <li key={reason} className="flex justify-between">
                  <span>막힘 · {HOLD_LABELS[reason]}</span>
                  <span>{execution.holds[reason]}번</span>
                </li>
              ))}
            </ul>
            <ul className="space-y-0.5 sm:col-span-2">
              <li className="flex justify-between">
                <span>AI 원가 · 청구 대상</span>
                <span>${usd(execution.cost.billableUsd, 4)}</span>
              </li>
              <li className="flex justify-between">
                <span>AI 원가 · 플랫폼 (계획 · 실패 · 응답 없는 시도)</span>
                <span>${usd(execution.cost.platformUsd, 4)}</span>
              </li>
              <li className="flex justify-between">
                <span>원가 미확정</span>
                <span>{execution.cost.unconfirmed}건</span>
              </li>
              <li className="flex justify-between">
                <span>청구 (정산한 크레딧)</span>
                <span>
                  {execution.charged.credits} 크레딧 · ${usd(execution.charged.usd, 4)}
                </span>
              </li>
            </ul>
          </CardContent>
        )}
      </Card>

      {/* OA I-oa 에이전트 카드 시작 */}
      <Card>
        <CardHeader>
          <CardTitle>에이전트 사용 (OA)</CardTitle>
          <CardDescription>
            {agents.usage
              ? `최근 ${days}일에 서버가 남긴 에이전트 · 프로젝트 · 이슈 정리 지표 이벤트의 수와 사용자 수입니다. 아래 칸은 같은 이벤트의 차원별 수입니다.`
              : "에이전트 사용 지표를 읽지 못했습니다 (서버 로그)."}
          </CardDescription>
        </CardHeader>
        {agents.usage && (
          <CardContent className="space-y-3 text-sm">
            {agents.usage.empty ? (
              <p className="text-muted-foreground">아직 에이전트 기록이 없습니다. 운영은 대화 v2 · adapter 플래그가 꺼져 있어(L5 전) 개발 계정 기록만 쌓입니다.</p>
            ) : (
              <ul className="space-y-1.5">
                {agents.usage.types
                  .filter((t) => t.n > 0)
                  .map((t) => (
                    <li key={t.type}>
                      <div className="flex justify-between gap-4">
                        <span>{AGENT_TYPE_LABELS[t.type] ?? t.type}</span>
                        <span className="shrink-0">
                          {t.n}번 · 사용자 {t.users}명
                        </span>
                      </div>
                      <p className="text-muted-foreground pl-3 text-xs">
                        {[
                          t.adapters.some((a) => a.value !== "(없음)") ? `adapter ${tallyText(t.adapters)}` : null,
                          ...t.dims.filter((d) => d.values.some((v) => v.value !== "(없음)")).map((d) => `${AGENT_DIM_LABELS[d.key] ?? d.key}: ${tallyText(d.values)}`),
                          t.numeric && t.numeric.n > 0 ? `서버 처리 ${t.numeric.key}: 표본 ${t.numeric.n} · p50 ${num(t.numeric.p50, "ms")} · p95 ${num(t.numeric.p95, "ms")}` : null,
                        ]
                          .filter(Boolean)
                          .join(" · ")}
                      </p>
                    </li>
                  ))}
              </ul>
            )}
            <p className="text-muted-foreground">
              기간 안에 0번: {agents.usage.types.filter((t) => t.n === 0).map((t) => AGENT_TYPE_LABELS[t.type] ?? t.type).join(" · ") || "없음"}
            </p>
            <p>
              에이전트에게 맡겨 생긴 이슈 {agents.usage.agentIssues.n}개 (사용자 {agents.usage.agentIssues.users}명)
            </p>
            {agents.usage.unknown.types > 0 && (
              <p className="text-destructive">
                등록부에 없는 type {agents.usage.unknown.types}개 ({agents.usage.unknown.events}건) — src/lib/metrics/agents.ts 등록부를 고치세요.
              </p>
            )}
            <p className="text-muted-foreground text-xs">
              도구 호출 결정은 서버 결정만 셉니다 (bridge 로컬 결정 · 사전 한도 거절 제외). 전달 시작은 사용자가 보낸 순간이 아니라 대기열 · 재전달 · Mac 복귀 때도 생겨 리텐션 활동에서 뺍니다.
            </p>
          </CardContent>
        )}
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>전달 · 지연 (ONE-TF-11 서버 구간)</CardTitle>
          <CardDescription>
            {agents.delivery
              ? `최근 ${days}일에 만든 전달 · 답 · 취소 단계. 만든 때 → Mac이 집어 간 때 → 접수한 때를 서버 시계끼리만 뺍니다. 기준은 3초 · 8초 · 25초이고 통과 · 실패는 MS-2 Mac 원장이 판정합니다 (Realtime 연결 여부 · CLI 입력 시각은 서버가 모릅니다). Claude Code의 접수는 그 턴의 첫 assistant 사건이라 모델의 첫 출력 시간이 들어 있는 상한입니다.`
              : "전달 · 지연을 읽지 못했습니다 (서버 로그)."}
          </CardDescription>
        </CardHeader>
        {agents.delivery && (
          <CardContent className="space-y-4 text-sm">
            {agents.delivery.groups.length === 0 ? (
              <p className="text-muted-foreground">기간 안에 만든 전달 단계가 없습니다.</p>
            ) : (
              agents.delivery.groups.map((g: LatencyGroup) => (
                <div key={`${g.kind}-${g.adapter}`}>
                  <p className="font-medium">
                    {LATENCY_KIND_LABELS[g.kind]} · {g.adapter} — 단계 {g.n}개
                  </p>
                  <ul className="text-muted-foreground space-y-0.5 pl-3">
                    <li>집어 감 (만든 때 → Mac): {quantileText(g.lease)}</li>
                    <li>{bucketText(g.buckets)}</li>
                    <li>
                      아직 기다림 {g.waiting} · 집힌 적 없이 끝남 {g.neverLeased}
                    </li>
                    <li>접수 (만든 때 → 첫 사건): {quantileText(g.accept)}</li>
                    {g.anomalies > 0 && <li>시각 이상으로 뺀 단계 {g.anomalies}</li>}
                  </ul>
                </div>
              ))
            )}
            <div>
              <p className="font-medium">전달 결과 (대화 메시지)</p>
              {agents.delivery.results.length === 0 ? (
                <p className="text-muted-foreground">기간 안에 전달 상태가 있는 메시지가 없습니다.</p>
              ) : (
                <ul className="space-y-0.5 pl-3">
                  {agents.delivery.results.map((r) => (
                    <li key={`${r.state}-${r.reason}`} className="flex justify-between gap-4">
                      <span>
                        {DELIVERY_STATE_LABELS[r.state] ?? r.state}
                        {r.reason !== "(없음)" && ` · ${DELIVERY_REASON_LABELS[r.reason] ?? r.reason}`}
                      </span>
                      <span>{r.n}개</span>
                    </li>
                  ))}
                </ul>
              )}
            </div>
            <div>
              <p className="font-medium">명령 결과 (bridge 명령)</p>
              {agents.delivery.commands.length === 0 ? (
                <p className="text-muted-foreground">기간 안에 명령이 없습니다.</p>
              ) : (
                <ul className="space-y-0.5 pl-3">
                  {agents.delivery.commands.map((c) => (
                    <li key={`${c.kind}-${c.outcome}`} className="flex justify-between gap-4">
                      <span>
                        {c.kind} · {COMMAND_OUTCOME_LABELS[c.outcome] ?? c.outcome}
                      </span>
                      <span>{c.n}개</span>
                    </li>
                  ))}
                </ul>
              )}
              {agents.delivery.commandsClamped && <p className="text-muted-foreground mt-1 text-xs">명령은 끝난 뒤 30일이 지나면 지워서, 명령 결과는 최근 30일만 셉니다.</p>}
            </div>
          </CardContent>
        )}
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>질문 → 답</CardTitle>
          <CardDescription>
            {agents.questions
              ? `최근 ${days}일에 서버가 받은 질문 ${agents.questions.asked}번. 기다린 시간은 서버가 질문 사건을 받은 때 → 답 단계를 만든 때입니다 (2초 보류 · 사람 생각 시간 포함, 다시 보낸 답은 첫 단계만).`
              : "질문 → 답을 읽지 못했습니다 (서버 로그)."}
          </CardDescription>
        </CardHeader>
        {agents.questions && (
          <CardContent className="space-y-2 text-sm">
            {agents.questions.groups.length === 0 ? (
              <p className="text-muted-foreground">기간 안에 받은 질문이 없습니다.</p>
            ) : (
              <ul className="space-y-1.5">
                {agents.questions.groups.map((g) => (
                  <li key={`${g.kind}-${g.path}`}>
                    <div className="flex justify-between gap-4">
                      <span>
                        {g.kind} · {QUESTION_PATH_LABELS[g.path]}
                      </span>
                      <span>{g.n}번</span>
                    </div>
                    {g.wait.n > 0 && <p className="text-muted-foreground pl-3 text-xs">기다린 시간 {quantileText(g.wait)}</p>}
                  </li>
                ))}
              </ul>
            )}
            {agents.questions.anomalies > 0 && <p className="text-muted-foreground">시각 이상으로 기다린 시간에서 뺀 질문 {agents.questions.anomalies}개</p>}
            <p className="text-muted-foreground text-xs">
              자유 글 답은 지표 행이 없어 답 단계로 셉니다.
              {agents.usage && ` 질문 답 지표(question_answered)는 ${agents.usage.types.find((t) => t.type === "question_answered")?.n ?? 0}번 — 카드 · 승인 · 로컬 답만 셉니다.`}
            </p>
          </CardContent>
        )}
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>멈춤 · 지금 막힌 것</CardTitle>
          <CardDescription>
            {agents.stops
              ? `최근 ${days}일에 대화 run이 멈춘 까닭과 끝난 턴, 그리고 지금(기간과 상관없이) 막힌 것입니다.`
              : "멈춤 · 막힘을 읽지 못했습니다 (서버 로그)."}
          </CardDescription>
        </CardHeader>
        {agents.stops && (
          <CardContent className="grid gap-4 text-sm sm:grid-cols-2">
            <ul className="space-y-0.5">
              {agents.stops.stopped.map((s) => (
                <li key={s.gate} className="flex justify-between">
                  <span>멈춤 · {STOP_GATE_LABELS[s.gate]}</span>
                  <span>{s.n}번</span>
                </li>
              ))}
              <li className="flex justify-between">
                <span>끝난 턴</span>
                <span>{agents.stops.turnsCompleted}번</span>
              </li>
            </ul>
            <ul className="space-y-0.5">
              <li className="flex justify-between">
                <span>만료한 lease (5초 넘게 남음)</span>
                <span>{agents.stops.now.overdueLeases}개</span>
              </li>
              <li className="flex justify-between">
                <span>결과 불명 단계</span>
                <span>{agents.stops.now.unknownOutcome}개</span>
              </li>
              <li className="flex justify-between">
                <span>연결이 끊긴 작업</span>
                <span>{agents.stops.now.unreachable}개</span>
              </li>
              <li className="flex justify-between">
                <span>답을 기다리는 작업</span>
                <span>{agents.stops.now.awaitingAnswer}개</span>
              </li>
              <li className="flex justify-between">
                <span>열린 경로 충돌 (가장 오래된 것의 나이)</span>
                <span>
                  {agents.stops.now.openConflicts}개 · {ageText(agents.stops.now.oldestConflictAgeS)}
                </span>
              </li>
            </ul>
            <p className="text-muted-foreground text-xs sm:col-span-2">결과 준비 → 검토 시간: 측정 전 — 검토 동작(E1c)이 생기면 남깁니다.</p>
          </CardContent>
        )}
      </Card>
      {/* OA I-oa 에이전트 카드 끝 */}

      <Card>
        <CardHeader>
          <CardTitle>연결 · 2단계 연동 요청</CardTitle>
          <CardDescription>
            기간 안에 연결을 마친 수 {connections.created}번 (사용자 {connections.users}명). 연결이 만료돼 다시 연결이 필요해진 수 {connections.expired}번 중
            알림이 기기에 간 수 {connections.notified}번 (알림 수가 적으면 기기가 없거나 알림을 받지 못한 만료가 있습니다). 아래는 2단계 연동의
            &quot;원해요&quot; 수 (전체 기간, 사용자마다 한 번)로, 많은 순서로 붙입니다 (원칙 6).
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          {connections.reconnect.length > 0 && (
            <div>
              <p className="text-muted-foreground mb-1">서비스별 재연결 (만료 · 알림 · 연결 완료)</p>
              <ul className="space-y-0.5">
                {connections.reconnect.map((r) => (
                  <li key={r.provider} className="flex justify-between">
                    <span>{PROVIDER_LABELS[r.provider] ?? r.provider}</span>
                    <span>
                      만료 {r.expired}번 · 알림 {r.notified}번 · 연결 완료 {r.created}번
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          )}
          {connections.requests.length === 0 ? (
            <p className="text-muted-foreground">아직 요청이 없습니다.</p>
          ) : (
            <ul className="space-y-0.5">
              {connections.requests.map((r) => (
                <li key={r.provider} className="flex justify-between">
                  <span>{PROVIDER_LABELS[r.provider] ?? r.provider}</span>
                  <span>{r.count}명</span>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Gmail 거르기</CardTitle>
          <CardDescription>
            Gmail 연결 {gmail.connections}개가 첫 동기화부터 결정한 메일 수 (전체 기간). 거른 메일은 머리글만 읽고 원문을 남기지 않아 여기서만 셉니다. 남긴
            메일 중 이미 넣은 것 · 넣기에 실패한 것이 있어 &quot;남김&quot;과 &quot;새 원문&quot;은 다를 수 있습니다. 개수는 연결 설정에 있어, 연결을 끊거나 다른
            계정으로 바꾸면 그 연결의 개수는 빠집니다.
          </CardDescription>
        </CardHeader>
        <CardContent className="text-sm">
          {gmail.connections === 0 ? (
            <p className="text-muted-foreground">아직 동기화한 Gmail 연결이 없습니다.</p>
          ) : (
            <ul className="space-y-0.5">
              {GMAIL_COUNT_LABELS.map(([key, label]) => (
                <li key={key} className="flex justify-between">
                  <span>{label}</span>
                  <span>{gmail.counts[key] ?? 0}통</span>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Google 회의 (Calendar · Meet)</CardTitle>
          <CardDescription>
            google 연결 {google.connections}개가 첫 동기화부터 센 개수 (전체 기간). 일정 자체는 저장하지 않아 붙은 결과만 셉니다. 개수는 연결 설정에 있어,
            연결을 끊거나 다른 계정으로 바꾸면 그 연결의 개수는 빠집니다.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          {google.connections === 0 ? (
            <p className="text-muted-foreground">아직 동기화한 google 연결이 없습니다.</p>
          ) : (
            <ul className="space-y-0.5">
              {GOOGLE_COUNT_LABELS.map(([key, label]) => (
                <li key={key} className="flex justify-between">
                  <span className="whitespace-pre">{label}</span>
                  <span>{google.counts[key] ?? 0}건</span>
                </li>
              ))}
            </ul>
          )}
          <div>
            <p className="font-medium">회의 원문에 일정이 붙은 비율 (최근 {days}일에 들어온 원문)</p>
            <ul className="space-y-0.5">
              <li className="flex justify-between">
                <span>Notion 회의록에 일정이 붙음 (Calendar를 허용한 사용자)</span>
                <span>
                  {linkage.notion.linked} / {linkage.notion.total}
                </span>
              </li>
              <li className="flex justify-between">
                <span className="pl-4">그중 같은 일정에 Meet 전사도 있음</span>
                <span>
                  {linkage.notion.withTranscript} / {linkage.notion.linked}
                </span>
              </li>
              <li className="flex justify-between">
                <span>Meet 전사에 일정이 붙음</span>
                <span>
                  {linkage.meet.linked} / {linkage.meet.total}
                </span>
              </li>
            </ul>
          </div>
        </CardContent>
      </Card>
    </main>
  );
}
