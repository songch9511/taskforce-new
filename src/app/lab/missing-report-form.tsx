"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { apiErrorSchema, missingReportResponseSchema, type MissingReportResponse } from "@/lib/api/contract";

// 내부 시험대용: 원문 구절을 붙여 넣어 빠진 할 일을 신고한다 (POST /api/v1/sources/:id/missing, 앱의 원문 화면과 같은 API).

const STAGE_LABELS: Record<NonNullable<MissingReportResponse["stage"]>, string> = {
  processing_failed: "원문 처리 실패 · 미완료",
  not_extracted: "추출 안 됨",
  judge_rejected: "Jev가 기각",
  merge_absorbed: "병합에서 합쳐짐",
};

export function MissingReportForm({ sourceId }: { sourceId: string }) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<MissingReportResponse | null>(null);

  async function onSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    setPending(true);
    setError(null);
    setResult(null);

    try {
      const response = await fetch(`/api/v1/sources/${sourceId}/missing`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ quote: new FormData(form).get("quote") }),
      });
      const json: unknown = await response.json();
      const parsed = missingReportResponseSchema.safeParse(json);
      if (!response.ok || !parsed.success) {
        const apiError = apiErrorSchema.safeParse(json);
        setError(apiError.success ? apiError.data.error.message : `요청 실패 (${response.status})`);
        return;
      }
      setResult(parsed.data);
      form.reset();
      router.refresh();
    } catch {
      setError("서버에 연결하지 못했습니다.");
    } finally {
      setPending(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="flex flex-col gap-2">
      <Label htmlFor="quote">빠진 할 일 신고 · 원문에서 내 할 일이 있는 구절을 그대로 붙여 넣으세요</Label>
      <textarea
        id="quote"
        name="quote"
        required
        rows={2}
        maxLength={2000}
        className="border-input placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-ring/50 rounded-md border bg-transparent px-3 py-2 font-mono text-sm outline-none focus-visible:ring-[3px]"
      />
      {error && (
        <p role="alert" className="text-destructive text-sm">
          {error}
        </p>
      )}
      {result && (
        <p className="text-sm">
          {result.status === "created" ? "추가했어요" : "이미 있는 할 일이에요"}: {result.action.title}
          {result.action.due_date && ` · 기한 ${result.action.due_date}`}
          {result.stage && <span className="text-muted-foreground"> · 놓친 단계: {STAGE_LABELS[result.stage]}</span>}
        </p>
      )}
      <Button type="submit" variant="outline" disabled={pending} className="self-start">
        {pending ? "신고하는 중…" : "신고하기"}
      </Button>
    </form>
  );
}
