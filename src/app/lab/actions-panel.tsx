"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/button";

// 내부 시험대용: 쓰기 API(확인 · 착수 · 삭제)와 AI에게 넘기기를 눌러 본다. 사용자용 화면은 앱에 만든다.

export type LabAction = {
  id: string;
  title: string;
  owner: string;
  due_date: string | null;
  counterpart: string | null;
  confirm_reasons: string[];
  reasons: string[];
  started_at: string | null;
};

const REASON_LABELS: Record<string, string> = {
  overdue: "기한 지남",
  due_today: "오늘 마감",
  due_soon: "곧 마감",
  external: "상대가 기다림",
  neglected: "오래 방치",
  started: "진행 중",
};

export function ActionsPanel({ now, confirmations }: { now: LabAction[]; confirmations: LabAction[] }) {
  const router = useRouter();
  const [pending, setPending] = useState<string | null>(null);
  const [handoff, setHandoff] = useState<{ title: string; markdown: string } | null>(null);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function call(id: string, path: string, method = "POST") {
    setPending(id);
    try {
      await fetch(`/api/v1/actions/${id}${path}`, { method });
      router.refresh();
    } finally {
      setPending(null);
    }
  }

  async function openHandoff(id: string) {
    setPending(id);
    try {
      setError(null);
      const response = await fetch(`/api/v1/actions/${id}/handoff`, { method: "POST" });
      if (response.ok) {
        setHandoff(await response.json());
        setCopied(false);
      } else {
        setError(`문서를 만들지 못했습니다 (${response.status}).`);
      }
    } finally {
      setPending(null);
    }
  }

  async function copy() {
    if (!handoff) return;
    try {
      await navigator.clipboard.writeText(handoff.markdown);
      setCopied(true);
    } catch {
      setError("복사하지 못했습니다. 문서를 직접 선택해 복사해 주세요.");
    }
  }

  const row = (a: LabAction, kind: "now" | "confirm") => (
    <li key={a.id} className="flex flex-wrap items-start justify-between gap-2 rounded-md border px-3 py-2 text-sm">
      <div>
        <div className="font-medium">{a.title}</div>
        <div className="text-muted-foreground">
          {[a.due_date && `기한 ${a.due_date}`, a.counterpart && `상대 ${a.counterpart}`, ...(kind === "confirm" ? a.confirm_reasons : a.reasons.map((r) => REASON_LABELS[r] ?? r))]
            .filter(Boolean)
            .join(" · ")}
        </div>
      </div>
      <div className="flex gap-1">
        {kind === "confirm" ? (
          <Button size="sm" disabled={pending !== null} onClick={() => call(a.id, "/confirm")}>
            맞아요
          </Button>
        ) : (
          <>
            <Button size="sm" variant="outline" disabled={pending !== null || Boolean(a.started_at)} onClick={() => call(a.id, "/start")}>
              {a.started_at ? "진행 중" : "시작"}
            </Button>
            <Button size="sm" variant="outline" disabled={pending !== null} onClick={() => openHandoff(a.id)}>
              AI에게 넘기기
            </Button>
          </>
        )}
        <Button size="sm" variant="ghost" disabled={pending !== null} onClick={() => call(a.id, "", "DELETE")}>
          {kind === "confirm" ? "아니에요" : "삭제"}
        </Button>
      </div>
    </li>
  );

  return (
    <div className="flex flex-col gap-4">
      {confirmations.length > 0 && (
        <div className="flex flex-col gap-2">
          <h3 className="text-sm font-semibold">확인 요청 {confirmations.length}</h3>
          <ul className="flex flex-col gap-2">{confirmations.map((a) => row(a, "confirm"))}</ul>
        </div>
      )}
      <div className="flex flex-col gap-2">
        <h3 className="text-sm font-semibold">지금 할 일 {now.length}</h3>
        {now.length === 0 ? <p className="text-muted-foreground text-sm">아직 없습니다.</p> : <ul className="flex flex-col gap-2">{now.map((a) => row(a, "now"))}</ul>}
      </div>
      {error && <p className="text-destructive text-sm">{error}</p>}
      {handoff && (
        <div className="flex flex-col gap-2">
          <div className="flex items-center justify-between gap-2">
            <h3 className="text-sm font-semibold">AI에게 넘길 문서: {handoff.title}</h3>
            <div className="flex gap-1">
              <Button size="sm" onClick={copy}>
                {copied ? "복사됨" : "복사"}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setHandoff(null)}>
                닫기
              </Button>
            </div>
          </div>
          <pre className="bg-muted max-h-96 overflow-auto rounded-md p-3 text-xs whitespace-pre-wrap">{handoff.markdown}</pre>
        </div>
      )}
    </div>
  );
}
