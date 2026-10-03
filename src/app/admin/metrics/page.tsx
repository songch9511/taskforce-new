import Link from "next/link";
import { notFound } from "next/navigation";

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { requireUser } from "@/lib/auth";
import { HOLD_REASONS, RUN_STATES, type ErrorField, type HoldReason, type MissedMetric, type RunState } from "@/lib/metrics/compute";
import { isAdmin, loadMetrics } from "@/lib/metrics/load";
import { createAdminClient } from "@/lib/supabase/admin";

// 관리자용 지표 (PRD 6장). 모든 사용자의 이벤트를 모아 숫자만 보여준다 — 원문 · 할 일 제목은 보여주지 않는다.
// ADMIN_EMAILS에 없는 사용자에게는 없는 페이지처럼 보인다.

const PERIODS = [7, 28, 90] as const;
const FIELD_LABELS: Record<ErrorField, string> = { title: "내용", due: "기한", owner: "담당", status: "상태", deleted: "삭제" };
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
            AI가 원문에서 만든 Action {m.aiCreated}개 중 사용자가 고치거나 지운 것 {m.corrected}개 (전체 {pct(m.rate)}). 완료 처리는 오판이 아닙니다. 할 일 DB에서 가져온 {m.imported}개는
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
