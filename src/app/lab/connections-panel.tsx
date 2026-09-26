"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/button";

export type ConnectionRow = {
  id: string;
  provider: string;
  display_name: string | null;
  status: "active" | "error" | "revoked";
  last_synced_at: string | null;
  last_error: string | null;
};

const STATUS_LABELS: Record<ConnectionRow["status"], string> = { active: "연결됨", error: "오류", revoked: "권한 끊김" };

const CALLBACK_MESSAGES: Record<string, string> = {
  connected: "Notion을 연결했습니다. '지금 동기화'를 누르면 최근 2주 회의록을 가져옵니다.",
  denied: "Notion 연결을 취소했습니다.",
  invalid_state: "연결 요청이 만료됐거나 올바르지 않습니다. 다시 시도해 주세요.",
  error: "Notion 연결에 실패했습니다. 서버 로그를 확인해 주세요.",
};

export function ConnectionsPanel({ connections, notionStatus }: { connections: ConnectionRow[]; notionStatus?: string }) {
  const router = useRouter();
  const [pending, setPending] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(notionStatus ? (CALLBACK_MESSAGES[notionStatus] ?? null) : null);

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

  async function disconnect(id: string) {
    if (!window.confirm("연결을 끊을까요? 이미 가져온 원문은 남습니다.")) return;
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
                <span className="font-medium">{c.provider === "notion" ? "Notion" : c.provider}</span>
                {c.display_name && <span className="text-muted-foreground"> · {c.display_name}</span>}
                <span className="text-muted-foreground"> · {STATUS_LABELS[c.status]}</span>
                {c.last_synced_at && (
                  <span className="text-muted-foreground">
                    {" "}
                    · 마지막 동기화 {new Date(c.last_synced_at).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })}
                  </span>
                )}
                {c.last_error && <div className="text-destructive">{c.last_error}</div>}
              </div>
              <Button variant="ghost" size="sm" disabled={pending !== null} onClick={() => disconnect(c.id)}>
                끊기
              </Button>
            </li>
          ))}
        </ul>
      )}
      <div className="flex flex-wrap items-center gap-3">
        <Button asChild variant="outline">
          <a href="/api/connectors/notion/start">{connections.some((c) => c.provider === "notion") ? "Notion 다시 연결 · 페이지 추가" : "Notion 연결"}</a>
        </Button>
        {connections.length > 0 && (
          <Button onClick={syncNow} disabled={pending !== null}>
            {pending === "sync" ? "동기화 중…" : "지금 동기화"}
          </Button>
        )}
      </div>
      {message && <p className="text-muted-foreground text-sm">{message}</p>}
    </div>
  );
}
