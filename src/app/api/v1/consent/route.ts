import { authenticateRequest } from "@/lib/api/auth";
import { handleGiveConsent, handleWithdrawConsent } from "@/lib/api/consent";
import { saveAiConsent } from "@/lib/api/profile-store";

// 외부 AI 처리 동의 (App Store 5.1.2(i)). POST { ai_processing: true } → 204, DELETE → 204 (철회).
const deps = { authenticate: authenticateRequest, save: saveAiConsent };

export async function POST(request: Request) {
  return handleGiveConsent(request, deps);
}

export async function DELETE(request: Request) {
  return handleWithdrawConsent(request, deps);
}
