import { after } from "next/server";

import { authenticateRequest } from "@/lib/api/auth";
import { resolveIdentity } from "@/lib/api/profile";
import { loadProfile } from "@/lib/api/profile-store";
import { handleCreateSource } from "@/lib/api/sources";
import { processSource } from "@/lib/sources/process";

// 파이프라인(추출 → 검증 → Jev)이 응답 뒤에 돌 시간을 준다.
export const maxDuration = 120;

export async function POST(request: Request) {
  return handleCreateSource(request, {
    authenticate: authenticateRequest,
    insertSource: async ({ supabase }, source) => {
      const { data } = await supabase.from("sources").insert(source).select("id").single().throwOnError();
      return data.id as string;
    },
    schedule: (context, sourceId, source, userName) => {
      after(async () => {
        const identity = resolveIdentity(await loadProfile(context).catch(() => null), context.user, userName);
        await processSource(context.supabase, sourceId, {
          text: source.raw_text,
          kind: source.kind,
          occurredAt: new Date(source.occurred_at),
          identity,
          participants: source.participants ?? undefined,
        });
      });
    },
  });
}
