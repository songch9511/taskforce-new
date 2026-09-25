import Link from "next/link";

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { EMPTY_PROFILE } from "@/lib/api/profile";
import { profileSchema } from "@/lib/api/contract";
import { requireUser } from "@/lib/auth";
import type { JudgeSignals, RejectReason } from "@/lib/pipeline/judge";
import type { VerifiedCandidate } from "@/lib/pipeline/verify";
import { createClient } from "@/lib/supabase/server";

import { AutoRefresh } from "./auto-refresh";
import { LabForm } from "./lab-form";
import { ProfileForm } from "./profile-form";

// 내부 시험대: 원문을 넣고 추출 → 기계 검증 → Jev 판정 결과를 표로 본다. 사용자용 화면이 아니다.

type SourceRow = {
  id: string;
  kind: string;
  raw_text: string;
  occurred_at: string;
  created_at: string;
  processing_status: "pending" | "processing" | "done" | "failed";
  processing_summary: Record<string, unknown> | null;
  processing_error: string | null;
};

type JudgeLogRow = {
  id: string;
  decision: "auto" | "confirm" | "reject";
  candidate: VerifiedCandidate;
  jev_answers: { signals: JudgeSignals; reasons: RejectReason[] };
  model_version: string;
};

const STATUS_LABELS: Record<SourceRow["processing_status"], string> = {
  pending: "대기",
  processing: "처리 중",
  done: "완료",
  failed: "실패",
};

const DECISION_LABELS: Record<JudgeLogRow["decision"], string> = { auto: "자동 반영", confirm: "확인 요청", reject: "기각" };
const DECISION_ORDER: JudgeLogRow["decision"][] = ["auto", "confirm", "reject"];

const pct = (p: number) => `${Math.round(p * 100)}%`;

export default async function LabPage({ searchParams }: { searchParams: Promise<{ source?: string }> }) {
  const user = await requireUser();
  const { source: selectedId } = await searchParams;
  const supabase = await createClient();

  const { data: profileRow } = await supabase.from("profiles").select("display_name, aliases, emails").maybeSingle();
  const profile = profileSchema.safeParse(profileRow).data ?? EMPTY_PROFILE;

  const { data: recent } = await supabase
    .from("sources")
    .select("id, kind, raw_text, occurred_at, created_at, processing_status, processing_summary, processing_error")
    .order("created_at", { ascending: false })
    .limit(10)
    .returns<SourceRow[]>();

  const { data: selected } = selectedId
    ? await supabase
        .from("sources")
        .select("id, kind, raw_text, occurred_at, created_at, processing_status, processing_summary, processing_error")
        .eq("id", selectedId)
        .returns<SourceRow[]>()
        .maybeSingle<SourceRow>()
    : { data: null };
  const { data: logs } = selected
    ? await supabase
        .from("judge_logs")
        .select("id, decision, candidate, jev_answers, model_version")
        .eq("source_id", selected.id)
        .returns<JudgeLogRow[]>()
    : { data: null };
  const sortedLogs = [...(logs ?? [])].sort((a, b) => DECISION_ORDER.indexOf(a.decision) - DECISION_ORDER.indexOf(b.decision));
  const running = selected && (selected.processing_status === "pending" || selected.processing_status === "processing");

  return (
    <main className="mx-auto flex w-full max-w-6xl flex-1 flex-col gap-6 p-6">
      <div className="flex items-baseline justify-between">
        <h1 className="text-2xl font-bold">시험대</h1>
        <span className="text-muted-foreground text-sm">내부용 · {user.email}</span>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>원문 넣기</CardTitle>
          <CardDescription>POST /api/v1/sources로 보내고, 추출 · 검증 · Jev 판정 결과를 아래에 보여줍니다.</CardDescription>
        </CardHeader>
        <CardContent>
          <LabForm />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>원문 속 나</CardTitle>
          <CardDescription>
            추출기가 원문에서 나를 알아보는 데 씁니다. 받아쓰기가 이름을 틀리게 적는다면 그 이름을 다른 이름에 넣으세요.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ProfileForm profile={profile} />
        </CardContent>
      </Card>

      {selected && (
        <Card>
          <CardHeader>
            <CardTitle>
              결과 · {STATUS_LABELS[selected.processing_status]}
              {running && <AutoRefresh />}
            </CardTitle>
            <CardDescription>
              {selected.kind} · 작성 {new Date(selected.occurred_at).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })}
              {selected.processing_summary && <> · {summaryText(selected.processing_summary)}</>}
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-col gap-4">
            {selected.processing_status === "failed" && (
              <p role="alert" className="text-destructive text-sm">
                {selected.processing_error}
              </p>
            )}
            {selected.processing_status === "done" && sortedLogs.length === 0 && (
              <p className="text-muted-foreground text-sm">뽑힌 후보가 없습니다.</p>
            )}
            {sortedLogs.length > 0 && (
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm">
                  <thead className="text-muted-foreground border-b">
                    <tr>
                      <th className="py-2 pr-3 font-medium">판정</th>
                      <th className="py-2 pr-3 font-medium">할 일 · 근거 인용</th>
                      <th className="py-2 pr-3 font-medium">담당</th>
                      <th className="py-2 pr-3 font-medium">기한</th>
                      <th className="py-2 pr-3 font-medium">내 약속</th>
                      <th className="py-2 pr-3 font-medium">할 일임</th>
                      <th className="py-2 pr-3 font-medium">이미 끝남</th>
                      <th className="py-2 pr-3 font-medium">확정도</th>
                      <th className="py-2 font-medium">사유</th>
                    </tr>
                  </thead>
                  <tbody>
                    {sortedLogs.map((log) => {
                      const { signals, reasons } = log.jev_answers;
                      return (
                        <tr key={log.id} className="border-b align-top last:border-0">
                          <td className="py-2 pr-3 whitespace-nowrap">{DECISION_LABELS[log.decision]}</td>
                          <td className="py-2 pr-3">
                            <div className="font-medium">{log.candidate.title}</div>
                            <div className="text-muted-foreground">“{log.candidate.quote}”</div>
                          </td>
                          <td className="py-2 pr-3 whitespace-nowrap">{log.candidate.owner === "me" ? "나" : "확인 필요"}</td>
                          <td className="py-2 pr-3 whitespace-nowrap">
                            {log.candidate.due ?? "—"}
                            {log.candidate.due_text && <div className="text-muted-foreground">{log.candidate.due_text}</div>}
                            {log.candidate.due_check === "corrected" && (
                              <div className="text-muted-foreground">모델 {log.candidate.model_due ?? "없음"} → 코드 보정</div>
                            )}
                          </td>
                          <td className="py-2 pr-3">{pct(signals.is_my_commitment)}</td>
                          <td className="py-2 pr-3">{pct(signals.is_actionable)}</td>
                          <td className="py-2 pr-3">{pct(signals.already_done)}</td>
                          <td className="py-2 pr-3">{signals.certainty.choice}</td>
                          <td className="py-2">{reasons.join(", ") || "—"}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
            <details>
              <summary className="text-muted-foreground cursor-pointer text-sm">원문 보기</summary>
              <pre className="bg-muted mt-2 max-h-96 overflow-auto rounded-md p-3 text-xs whitespace-pre-wrap">{selected.raw_text}</pre>
            </details>
          </CardContent>
        </Card>
      )}

      {recent && recent.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>최근 원문</CardTitle>
          </CardHeader>
          <CardContent>
            <ul className="flex flex-col gap-2 text-sm">
              {recent.map((source) => (
                <li key={source.id}>
                  <Link href={`/lab?source=${source.id}`} className="hover:underline">
                    {new Date(source.created_at).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })} · {source.kind} ·{" "}
                    {STATUS_LABELS[source.processing_status]}
                    {source.processing_summary && <> · {summaryText(source.processing_summary)}</>}
                  </Link>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}
    </main>
  );
}

function summaryText(summary: Record<string, unknown>): string {
  const n = (key: string) => (typeof summary[key] === "number" ? (summary[key] as number) : 0);
  const cost = typeof summary.cost === "number" ? ` · $${summary.cost.toFixed(4)}` : "";
  return `추출 ${n("extracted")} · 자동 ${n("auto")} · 확인 ${n("confirm")} · 기각 ${n("reject")} · 환각 ${n("dropped")}${cost}`;
}
