"use client";

import { useActionState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

import { sendMagicLink, type LoginState } from "./actions";

const initialState: LoginState = { status: "idle" };

export function LoginForm() {
  const [state, formAction, pending] = useActionState(sendMagicLink, initialState);

  if (state.status === "sent") {
    return (
      <p className="text-sm leading-6">
        <strong>{state.email}</strong>로 로그인 링크를 보냈습니다. 메일함에서 링크를 눌러 주세요.
      </p>
    );
  }

  return (
    <form action={formAction} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label htmlFor="email">이메일</Label>
        <Input
          id="email"
          name="email"
          type="email"
          autoComplete="email"
          placeholder="you@company.com"
          defaultValue={state.status === "error" ? state.email : undefined}
          required
          aria-invalid={state.status === "error"}
        />
      </div>
      {state.status === "error" && (
        <p role="alert" className="text-destructive text-sm">
          {state.message}
        </p>
      )}
      <Button type="submit" disabled={pending}>
        {pending ? "보내는 중…" : "로그인 링크 받기"}
      </Button>
    </form>
  );
}
