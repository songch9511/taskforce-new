import { notFound } from "next/navigation";

import { requireUser } from "@/lib/auth";
import { isAdmin } from "@/lib/metrics/load";

// 내부 시험대는 운영자(ADMIN_EMAILS)만 연다. 이용자는 내부 화면을 쓰지 않는다 (처리방침 10장). 그 밖의 사용자에게는 없는 페이지처럼 404.
// /lab 아래 경로의 기본 막이일 뿐이다: 레이아웃은 하위 페이지 · Server Action · Route Handler를 막지 못하므로(Next 인증 가이드) 각자 같은 확인을 한다.
export default async function LabLayout({ children }: LayoutProps<"/lab">) {
  const user = await requireUser();
  if (!isAdmin(user.email)) notFound();
  return children;
}
