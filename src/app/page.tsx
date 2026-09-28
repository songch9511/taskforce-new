import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { requireUser } from "@/lib/auth";

export default async function HomePage() {
  const user = await requireUser();

  return (
    <div className="flex flex-1 flex-col">
      <header className="flex items-center justify-between border-b px-6 py-4">
        <span className="font-semibold">Taskforce</span>
        <div className="flex items-center gap-3">
          <span className="text-muted-foreground text-sm">{user.email}</span>
          <form action="/auth/signout" method="post">
            <Button type="submit" variant="ghost" size="sm">
              로그아웃
            </Button>
          </form>
        </div>
      </header>

      <main className="mx-auto flex w-full max-w-2xl flex-1 flex-col gap-6 p-6">
        <h1 className="text-2xl font-bold">지금 할 일</h1>
        <Card>
          <CardHeader>
            <CardTitle>아직 할 일이 없어요</CardTitle>
            <CardDescription>
              회의록이나 메시지를 넣으면 Taskforce가 내가 약속한 일을 찾아 여기에 정리합니다.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Button disabled>원문 넣기 (준비 중)</Button>
          </CardContent>
        </Card>
      </main>
    </div>
  );
}
