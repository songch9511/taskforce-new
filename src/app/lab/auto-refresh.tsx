"use client";

import { useRouter } from "next/navigation";
import { useEffect } from "react";

// 파이프라인이 끝날 때까지 서버 컴포넌트를 주기적으로 다시 그린다.
export function AutoRefresh({ intervalMs = 2000 }: { intervalMs?: number }) {
  const router = useRouter();
  useEffect(() => {
    const timer = setInterval(() => router.refresh(), intervalMs);
    return () => clearInterval(timer);
  }, [router, intervalMs]);
  return null;
}
