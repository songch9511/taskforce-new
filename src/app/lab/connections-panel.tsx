"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/button";

import { DataSourcesPanel } from "./data-sources-panel";

export type ConnectionRow = {
  id: string;
  provider: string;
  display_name: string | null;
  status: "active" | "error" | "revoked" | "reauth";
  last_synced_at: string | null;
  last_error: string | null;
  settings?: { health?: { unreachable: { id: string; title: string | null }[] } } | null;
};

const STATUS_LABELS: Record<ConnectionRow["status"], string> = { active: "연결됨", error: "오류", revoked: "권한 끊김", reauth: "다시 연결 필요" };

const CALLBACK_MESSAGES: Record<string, string> = {
  connected: "Notion을 연결했습니다. '지금 동기화'를 누르면 최근 2주 회의록을 가져옵니다. 아래 '데이터베이스 역할 설정'에서 할 일 데이터베이스를 확인해 주세요.",
  connected_no_meetings:
    "Notion을 연결했지만 회의록 데이터베이스가 보이지 않습니다. 회의록이 Taskforce의 가장 중요한 원문입니다. 'Notion 다시 연결 · 페이지 추가'에서 회의록 데이터베이스를 검색해 체크해 주세요 (방금 골랐다면 반영에 몇 분 걸릴 수 있습니다).",
  connected_empty:
    "Notion을 연결했지만 지금 읽을 수 있는 페이지 · 데이터베이스가 없습니다. 다시 연결할 때는 선택 화면에서 읽을 곳을 다시 체크해야 합니다 (전에 고른 것도 이번 선택에 없으면 끊깁니다). 'Notion 다시 연결 · 페이지 추가'에서 회의록 · 할 일 데이터베이스를 고르세요. 방금 골랐다면 반영에 몇 분 걸릴 수 있습니다.",
  denied: "Notion 연결을 취소했습니다.",
  invalid_state: "연결 요청이 만료됐거나 올바르지 않습니다. 다시 시도해 주세요.",
  error: "Notion 연결에 실패했습니다. 서버 로그를 확인해 주세요.",
  consent_required: "연결하기 전에 위의 '외부 AI 처리 동의'를 먼저 해 주세요. 연결하면 곧바로 원문을 가져와 처리합니다.",
};

const SLACK_CALLBACK_MESSAGES: Record<string, string> = {
  connected:
    "Slack을 연결했습니다. 지금부터 오는 DM · 그룹 DM과, 나를 부르거나 내가 쓴 채널 글(그 스레드 포함)을 받습니다. 과거 메시지는 가져오지 않습니다. 대화가 30분 멈추면 동기화(15분마다 · '지금 동기화')가 원문으로 넣습니다.",
  denied: "Slack 연결을 취소했습니다.",
  unavailable: "Slack 연결은 아직 운영자만 시험할 수 있습니다 (SLACK_CONNECT_ENABLED · ADMIN_EMAILS).",
  invalid_state: CALLBACK_MESSAGES.invalid_state,
  error: "Slack 연결에 실패했습니다. 서버 로그를 확인해 주세요.",
  consent_required: CALLBACK_MESSAGES.consent_required,
};

const PROVIDER_LABELS: Record<string, string> = { notion: "Notion", slack: "Slack" };

/** 권한 화면에 들어가기 전에 보여준다: 한 번에 제대로 고르게 (다른 Notion 연동 도구들이 겪는 "DB가 안 보여요"를 줄인다) */
function ConnectChecklist({ reconnect }: { reconnect: boolean }) {
  return (
    <div className="bg-muted flex flex-col gap-2 rounded-md p-3 text-sm">
      <p className="font-medium">Notion 권한 화면에서 이렇게 골라 주세요</p>
      <ol className="list-decimal space-y-1 pl-5">
        <li>
          <b>회의록 데이터베이스</b> (예: Meeting) — 가장 중요한 원문입니다.
        </li>
        <li>
          <b>할 일 데이터베이스</b> (예: Action Items, Action) — 이미 적힌 일과 중복을 만들지 않고, 완료를 따라갑니다.
        </li>
        <li>
          팀스페이스 <b>맨 위에 있는 데이터베이스</b>는 그 자체를 검색해 체크하세요. 상위 페이지를 골라도 포함되지 않습니다.
        </li>
        <li>
          회의록 안의 &apos;링크된 보기&apos;(예: View of Action Items)는 <b>원본 데이터베이스</b>를 골라야 읽힙니다.
        </li>
        {reconnect && (
          <li>
            다시 연결할 때는 <b>이미 체크된 항목을 해제하지 마세요</b>. 이번 선택에 없는 것은 전에 읽던 것이라도 끊깁니다.
          </li>
        )}
      </ol>
      <p className="text-muted-foreground">워크스페이스 전체를 고를 필요는 없습니다. 목표 · 투표처럼 약속이 나오지 않는 곳은 고르지 않아도 됩니다.</p>
    </div>
  );
}

export function ConnectionsPanel({ connections, notionStatus, slackStatus }: { connections: ConnectionRow[]; notionStatus?: string; slackStatus?: string }) {
  const router = useRouter();
  const [pending, setPending] = useState<string | null>(null);
  const [showChecklist, setShowChecklist] = useState(false);
  const hasNotion = connections.some((c) => c.provider === "notion");
  const [message, setMessage] = useState<string | null>(
    notionStatus ? (CALLBACK_MESSAGES[notionStatus] ?? null) : slackStatus ? (SLACK_CALLBACK_MESSAGES[slackStatus] ?? null) : null,
  );

  async function syncNow() {
    setPending("sync");
    setMessage(null);
    try {
      const response = await fetch("/api/v1/connections/sync", { method: "POST" });
      const body = (await response.json()) as {
        connections?: { ok: boolean; created?: number; scanned?: number; error?: string }[];
        error?: { message: string };
      };
      if (!response.ok) {
        setMessage(body.error?.message ?? `동기화 실패 (${response.status})`);
        return;
      }
      const results = body.connections ?? [];
      const created = results.reduce((n, c) => n + (c.created ?? 0), 0);
      const scanned = results.reduce((n, c) => n + (c.scanned ?? 0), 0);
      const errors = results.filter((c) => !c.ok).map((c) => c.error);
      setMessage(errors.length ? `오류: ${errors.join(" / ")}` : `페이지 ${scanned}개를 확인해 새 원문 ${created}건을 넣었습니다.`);
      router.refresh();
    } catch {
      setMessage("서버에 연결하지 못했습니다.");
    } finally {
      setPending(null);
    }
  }

  async function disconnect(id: string, provider: string) {
    const warning =
      provider === "slack" ? "연결을 끊을까요? Slack에서 가져온 글과 근거 인용이 지워지고, 할 일은 남습니다." : "연결을 끊을까요? 이미 가져온 원문은 남습니다.";
    if (!window.confirm(warning)) return;
    setPending(id);
    try {
      await fetch(`/api/v1/connections/${id}`, { method: "DELETE" });
      router.refresh();
    } finally {
      setPending(null);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      {connections.length > 0 && (
        <ul className="flex flex-col gap-2 text-sm">
          {connections.map((c) => (
            <li key={c.id} className="flex flex-wrap items-center justify-between gap-2 rounded-md border px-3 py-2">
              <div>
                <span className="font-medium">{PROVIDER_LABELS[c.provider] ?? c.provider}</span>
                {c.display_name && <span className="text-muted-foreground"> · {c.display_name}</span>}
                <span className="text-muted-foreground"> · {STATUS_LABELS[c.status]}</span>
                {c.last_synced_at && (
                  <span className="text-muted-foreground">
                    {" "}
                    · 마지막 동기화 {new Date(c.last_synced_at).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })}
                  </span>
                )}
                {c.last_error && <div className="text-destructive">{c.last_error}</div>}
                {(c.settings?.health?.unreachable.length ?? 0) > 0 && (
                  <div className="text-destructive">
                    읽을 수 없게 된 데이터베이스: {c.settings!.health!.unreachable.map((d) => d.title ?? "제목 없음").join(", ")}. 여기서 나오는 원문이 들어오지
                    않습니다. Notion에서 그 데이터베이스를 열고 ••• → 연결 → Taskforce를 추가하거나, &apos;Notion 다시 연결 · 페이지 추가&apos;에서 다시 체크해
                    주세요.
                  </div>
                )}
              </div>
              <Button variant="ghost" size="sm" disabled={pending !== null} onClick={() => disconnect(c.id, c.provider)}>
                끊기
              </Button>
              {c.provider === "notion" && c.status !== "revoked" && c.status !== "reauth" && (
                <div className="w-full">
                  <DataSourcesPanel connectionId={c.id} />
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
      {showChecklist && <ConnectChecklist reconnect={hasNotion} />}
      <div className="flex flex-wrap items-center gap-3">
        {showChecklist ? (
          <>
            <Button asChild>
              <a href="/api/connectors/notion/start">확인했어요 · Notion으로 이동</a>
            </Button>
            <Button variant="ghost" onClick={() => setShowChecklist(false)}>
              취소
            </Button>
          </>
        ) : (
          <Button variant="outline" onClick={() => setShowChecklist(true)}>
            {hasNotion ? "Notion 다시 연결 · 페이지 추가" : "Notion 연결"}
          </Button>
        )}
        <Button variant="outline" asChild>
          <a href="/api/connectors/slack/start">{connections.some((c) => c.provider === "slack") ? "Slack 다시 연결" : "Slack 연결"}</a>
        </Button>
        {connections.length > 0 && (
          <Button onClick={syncNow} disabled={pending !== null}>
            {pending === "sync" ? "동기화 중…" : "지금 동기화"}
          </Button>
        )}
      </div>
      {message && (
        <p className={`text-sm ${message === CALLBACK_MESSAGES.connected_empty || message === CALLBACK_MESSAGES.connected_no_meetings ? "text-destructive" : "text-muted-foreground"}`}>
          {message}
        </p>
      )}
    </div>
  );
}
