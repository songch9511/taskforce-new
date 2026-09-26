"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { apiErrorSchema, type Profile } from "@/lib/api/contract";
import { parseList } from "@/lib/api/people";

// 원문 속 사용자를 알아보는 정보. 받아쓰기가 이름을 틀리게 적는다면(예: 도윤 → 도연) 그 이름을 별칭에 넣는다.
export function ProfileForm({ profile }: { profile: Profile }) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function onSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    setMessage(null);
    try {
      const response = await fetch("/api/v1/profile", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          display_name: String(form.get("display_name") ?? "").trim() || null,
          aliases: parseList(String(form.get("aliases") ?? "")),
          emails: parseList(String(form.get("emails") ?? "")),
        }),
      });
      if (!response.ok) {
        const error = apiErrorSchema.safeParse(await response.json());
        setMessage(error.success ? error.data.error.message : `저장 실패 (${response.status})`);
        return;
      }
      setMessage("저장했습니다.");
      router.refresh();
    } catch {
      setMessage("서버에 연결하지 못했습니다.");
    } finally {
      setPending(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="flex flex-col gap-4">
      <div className="grid gap-4 sm:grid-cols-3">
        <div className="flex flex-col gap-2">
          <Label htmlFor="display_name">원문 속 기본 이름</Label>
          <Input id="display_name" name="display_name" defaultValue={profile.display_name ?? ""} placeholder="예: 도윤" />
        </div>
        <div className="flex flex-col gap-2">
          <Label htmlFor="aliases">다른 이름 (쉼표로)</Label>
          <Input id="aliases" name="aliases" defaultValue={profile.aliases.join(", ")} placeholder="예: 도연, Doyun, 윤님" />
        </div>
        <div className="flex flex-col gap-2">
          <Label htmlFor="emails">내 이메일 (쉼표로)</Label>
          <Input id="emails" name="emails" defaultValue={profile.emails.join(", ")} placeholder="로그인 주소 외 회사 · 개인 주소" />
        </div>
      </div>
      <div className="flex items-center gap-3">
        <Button type="submit" variant="outline" disabled={pending}>
          {pending ? "저장 중…" : "저장"}
        </Button>
        {message && <span className="text-muted-foreground text-sm">{message}</span>}
      </div>
    </form>
  );
}
