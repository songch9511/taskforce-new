"use client";

import { useActionState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

import { sendCode, verifyCode, type LoginState } from "./actions";

const initialState: LoginState = { status: "idle" };

export function LoginForm() {
  const [sendState, sendAction, sending] = useActionState(sendCode, initialState);
  const [verifyState, verifyAction, verifying] = useActionState(verifyCode, initialState);

  // 코드를 보낸 뒤: 코드 입력 (틀리면 같은 칸에 오류, 다시 받으려면 새로고침 없이 처음 칸으로)
  if (sendState.status === "sent") {
    const error = verifyState.status === "sent" ? verifyState.error : undefined;
    return (
      <form action={verifyAction} className="flex flex-col gap-4">
        <p className="text-sm leading-6">
          <strong>{sendState.email}</strong>로 6자리 코드를 보냈습니다. 메일함에서 확인해 주세요.
        </p>
        <input type="hidden" name="email" value={sendState.email} />
        <div className="flex flex-col gap-2">
          <Label htmlFor="token">코드</Label>
          <Input
            id="token"
            name="token"
            inputMode="numeric"
            autoComplete="one-time-code"
            placeholder="123456"
            maxLength={12}
            required
            aria-invalid={error !== undefined}
          />
        </div>
        {error && (
          <p role="alert" className="text-destructive text-sm">
            {error}
          </p>
        )}
        <Button type="submit" disabled={verifying}>
          {verifying ? "확인하는 중…" : "로그인"}
        </Button>
      </form>
    );
  }

  return (
    <form action={sendAction} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label htmlFor="email">이메일</Label>
        <Input
          id="email"
          name="email"
          type="email"
          autoComplete="email"
          placeholder="you@company.com"
          defaultValue={sendState.status === "error" ? sendState.email : undefined}
          required
          aria-invalid={sendState.status === "error"}
        />
      </div>
      {sendState.status === "error" && (
        <p role="alert" className="text-destructive text-sm">
          {sendState.message}
        </p>
      )}
      <Button type="submit" disabled={sending}>
        {sending ? "보내는 중…" : "로그인 코드 받기"}
      </Button>
    </form>
  );
}
