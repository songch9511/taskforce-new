import { authenticateRequest } from "@/lib/api/auth";
import { handleCreateWorkContext } from "@/lib/api/contexts";
import { createContext } from "@/lib/context/store";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 프로젝트 만들기 (D4c-1s). `MEMORY_ENABLED` off는 404이며 인증 · DB를 호출하지 않는다.
export async function POST(request: Request) {
  return handleCreateWorkContext(request, {
    enabled: () => flagEnabled("MEMORY_ENABLED"),
    authenticate: authenticateRequest,
    create: ({ user }, input) => createContext(createAdminClient(), user.id, input),
  });
}
