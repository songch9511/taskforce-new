import type { Metadata } from "next";

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

import { LoginForm } from "./login-form";

export const metadata: Metadata = {
  title: "로그인 · Taskforce",
};

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const { error } = await searchParams;

  return (
    <main className="flex flex-1 items-center justify-center p-6">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle className="text-xl">Taskforce</CardTitle>
          <CardDescription>이메일로 받은 링크를 누르면 로그인됩니다.</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          {error === "link" && (
            <p role="alert" className="text-destructive text-sm">
              로그인 링크가 만료되었거나 올바르지 않습니다. 다시 받아 주세요.
            </p>
          )}
          <LoginForm />
        </CardContent>
      </Card>
    </main>
  );
}
