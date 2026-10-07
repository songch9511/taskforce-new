import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: NextRequest) {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.signInWithOAuth({ provider: "google", options: { redirectTo: `${request.nextUrl.origin}/auth/billing`, queryParams: { prompt: "select_account" } } });
  if (error || !data.url) return NextResponse.redirect(new URL("/billing?error=sign-in", request.url));
  return NextResponse.redirect(data.url);
}
