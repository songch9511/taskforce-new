import { authenticateRequest } from "@/lib/api/auth";
import { handleConfirmMemory } from "@/lib/api/memory";
import { confirmMemoryItem } from "@/lib/context/memory-writes";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 추정 후보 확인 (B3, 구현 계획 7장). gate MEMORY_ENABLED가 꺼져 있으면 404. 사용자의 명시적 요청만 확인이다(모델 판단 · 화면을 열어 본 것은 아니다).
// 200 { item } 새 explicit 행 · 404 없는/남의 기억 · 409 conflict(version · 이미 정정 · 잊음) · 409 confirm_unavailable(Slack 원문에서 온 후보 · 추정이 아닌 항목: 정책 보류). AI를 부르지 않는다.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleConfirmMemory(request, id, {
    enabled: () => flagEnabled("MEMORY_ENABLED"),
    authenticate: authenticateRequest,
    confirm: ({ user }, memoryId, body) => confirmMemoryItem(createAdminClient(), user.id, memoryId, body.expected_version),
  });
}
