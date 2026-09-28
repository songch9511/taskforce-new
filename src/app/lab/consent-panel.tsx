"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/button";

// 외부 AI 처리 동의 (POST · DELETE /api/v1/consent). 동의 전에는 원문 넣기 · 동기화 · 연결 시작이 409로 막힌다.
// 기존 계정도 한 번 동의해야 한다 (자동으로 동의한 것으로 바꾸지 않는다).
export function ConsentPanel({ consentedAt }: { consentedAt: string | null }) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function toggle() {
    setPending(true);
    setMessage(null);
    try {
      const response = await fetch("/api/v1/consent", {
        method: consentedAt ? "DELETE" : "POST",
        headers: { "Content-Type": "application/json" },
        body: consentedAt ? undefined : JSON.stringify({ ai_processing: true }),
      });
      if (!response.ok) {
        setMessage(`저장 실패 (${response.status})`);
        return;
      }
      router.refresh();
    } catch {
      setMessage("서버에 연결하지 못했습니다.");
    } finally {
      setPending(false);
    }
  }

  return (
    <div className="flex flex-wrap items-center gap-3 text-sm">
      <span>{consentedAt ? `동의함 (${new Date(consentedAt).toLocaleString("ko-KR")})` : "동의 전: 원문 넣기 · 동기화 · 연결이 막혀 있습니다."}</span>
      <Button type="button" size="sm" variant={consentedAt ? "outline" : "default"} disabled={pending} onClick={toggle}>
        {consentedAt ? "동의 철회" : "동의하기"}
      </Button>
      {message && <span className="text-destructive">{message}</span>}
    </div>
  );
}
