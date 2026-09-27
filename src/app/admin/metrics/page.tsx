import Link from "next/link";
import { notFound } from "next/navigation";

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { requireUser } from "@/lib/auth";
import type { ErrorField, MissedMetric } from "@/lib/metrics/compute";
import { isAdmin, loadMetrics } from "@/lib/metrics/load";
import { createAdminClient } from "@/lib/supabase/admin";

// 관리자용 지표 (PRD 6장). 모든 사용자의 이벤트를 모아 숫자만 보여준다 — 원문 · 할 일 제목은 보여주지 않는다.
// ADMIN_EMAILS에 없는 사용자에게는 없는 페이지처럼 보인다.

const PERIODS = [7, 28, 90] as const;
const FIELD_LABELS: Record<ErrorField, string> = { title: "내용", due: "기한", owner: "담당", status: "상태", deleted: "삭제" };
const MISS_STAGE_LABELS: Record<keyof MissedMetric["byStage"], string> = {
  not_extracted: "추출 안 됨 (검증 탈락 포함)",
  judge_rejected: "Jev가 기각",
  merge_absorbed: "병합에서 다른 Action에 합쳐짐",
  processing_failed: "원문 처리 실패 · 미완료",
  unknown: "단계 기록 없음",
};

const pct = (value: number | null) => (value === null ? "—" : `${Math.round(value * 1000) / 10}%`);
const num = (value: number | null, unit = "") => (value === null ? "—" : `${Math.round(value * 10) / 10}${unit}`);

export default async function MetricsPage({ searchParams }: { searchParams: Promise<{ days?: string }> }) {
  const user = await requireUser();
  if (!isAdmin(user.email)) notFound();

  const { days: daysParam } = await searchParams;
  const days = PERIODS.find((d) => String(d) === daysParam) ?? 28;
  const to = new Date();
  const report = await loadMetrics(createAdminClient(), { from: new Date(to.getTime() - days * 86_400_000), to });
  const { misjudgment: m, start, retention, missed, shadowList: shadow } = report;
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
            신고된 누락 {missed.reported}개 / (AI 생성 {m.aiCreated}개 + 신고된 누락). 사용자가 원문 구절을 골라 신고한 것만 세므로 실제 누락의 하한입니다. 이미 있던 할
            일로 합쳐진 신고는 세지 않고, 신고로 생긴 Action은 지표 1에서 뺐습니다.
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
    </main>
  );
}
