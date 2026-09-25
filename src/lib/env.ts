import { z } from "zod";

const publicEnvSchema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z
    .url()
    .refine((url) => !URL.parse(url)?.pathname.startsWith("/dashboard"), {
      message: "대시보드 주소가 아니라 API 주소(https://<프로젝트 ref>.supabase.co)를 넣어야 합니다",
    }),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z.string().min(1),
});

export type PublicEnv = z.infer<typeof publicEnvSchema>;

export function parsePublicEnv(source: Record<string, string | undefined>): PublicEnv {
  const result = publicEnvSchema.safeParse(source);
  if (!result.success) {
    const problems = result.error.issues
      .map((issue) => `${issue.path.join(".")} (${issue.message})`)
      .join(", ");
    throw new Error(`환경변수가 없거나 잘못되었습니다: ${problems}. .env.example을 참고해 .env.local을 채우세요.`);
  }
  return result.data;
}

// NEXT_PUBLIC_* 값은 빌드 때 브라우저 번들에 인라인되므로 process.env.X 형태로 직접 참조해야 한다.
export function publicEnv(): PublicEnv {
  return parsePublicEnv({
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  });
}
