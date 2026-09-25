"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { apiErrorSchema, createSourceResponseSchema, sourceKindSchema } from "@/lib/api/contract";

const KIND_LABELS: Record<string, string> = { meeting: "회의록", message: "메시지", email: "메일", doc: "문서", note: "메모" };

// datetime-local 값(시간대 없음)을 브라우저 시간대의 오프셋을 붙인 ISO 문자열로 바꾼다.
function toOffsetIso(local: string): string {
  const date = new Date(local);
  const offset = -date.getTimezoneOffset();
  const sign = offset >= 0 ? "+" : "-";
  const pad = (n: number) => String(Math.floor(Math.abs(n))).padStart(2, "0");
  return `${local.length === 16 ? `${local}:00` : local}${sign}${pad(offset / 60)}:${pad(offset % 60)}`;
}

function nowLocal(): string {
  const date = new Date();
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 16);
}

export function LabForm({ defaultUserName }: { defaultUserName: string }) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    setError(null);

    try {
      const response = await fetch("/api/v1/sources", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          kind: form.get("kind"),
          text: form.get("text"),
          occurred_at: toOffsetIso(String(form.get("occurred_at"))),
          user_name: String(form.get("user_name") ?? "").trim() || undefined,
        }),
      });
      const json: unknown = await response.json();
      const created = createSourceResponseSchema.safeParse(json);
      if (!response.ok || !created.success) {
        const apiError = apiErrorSchema.safeParse(json);
        setError(apiError.success ? apiError.data.error.message : `요청 실패 (${response.status})`);
        return;
      }
      router.push(`/lab?source=${created.data.source_id}`);
    } catch {
      setError("서버에 연결하지 못했습니다.");
    } finally {
      setPending(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="flex flex-col gap-4">
      <div className="grid gap-4 sm:grid-cols-3">
        <div className="flex flex-col gap-2">
          <Label htmlFor="kind">종류</Label>
          <select id="kind" name="kind" defaultValue="meeting" className="border-input h-9 rounded-md border bg-transparent px-3 text-sm">
            {sourceKindSchema.options.map((kind) => (
              <option key={kind} value={kind}>
                {KIND_LABELS[kind]}
              </option>
            ))}
          </select>
        </div>
        <div className="flex flex-col gap-2">
          <Label htmlFor="occurred_at">작성 시점</Label>
          <Input id="occurred_at" name="occurred_at" type="datetime-local" defaultValue={nowLocal()} required />
        </div>
        <div className="flex flex-col gap-2">
          <Label htmlFor="user_name">원문 속 내 이름</Label>
          <Input id="user_name" name="user_name" defaultValue={defaultUserName} placeholder="예: 나, 도윤" />
        </div>
      </div>
      <div className="flex flex-col gap-2">
        <Label htmlFor="text">원문</Label>
        <textarea
          id="text"
          name="text"
          required
          rows={12}
          placeholder="회의록 · 메시지 · 메일을 붙여넣으세요"
          className="border-input placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-ring/50 rounded-md border bg-transparent px-3 py-2 font-mono text-sm outline-none focus-visible:ring-[3px]"
        />
      </div>
      {error && (
        <p role="alert" className="text-destructive text-sm">
          {error}
        </p>
      )}
      <Button type="submit" disabled={pending} className="self-start">
        {pending ? "보내는 중…" : "추출하기"}
      </Button>
    </form>
  );
}
