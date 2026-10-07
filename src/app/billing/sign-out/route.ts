import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { isCrossSiteWrite } from "@/lib/api/csrf";

export async function POST(request: Request) {
  if (isCrossSiteWrite(request)) return new Response(null, { status: 403 });
  await (await createClient()).auth.signOut({ scope: "local" });
  return NextResponse.redirect(new URL("/billing", request.url), 303);
}
