import "server-only";

import { Buffer } from "node:buffer";

import { AuthInvalidJwtError, type SupabaseClient } from "@supabase/supabase-js";

function hasMalformedJwtHeaderShape(token: string): boolean {
  const encodedHeader = token.split(".", 1)[0];
  let header: unknown;

  try {
    header = JSON.parse(Buffer.from(encodedHeader, "base64url").toString("utf8"));
  } catch {
    return false;
  }

  if (header === null) return true;
  if (typeof header !== "object" || Array.isArray(header)) return false;
  const algorithm = (header as { alg?: unknown }).alg;
  return Boolean(algorithm) && typeof algorithm !== "string";
}

function invalidJwt() {
  return { data: null, error: new AuthInvalidJwtError("Invalid JWT") };
}

// auth-js returns invalid JWTs as AuthErrors except when token decoding throws before validation.
export async function getVerifiedClaims(supabase: SupabaseClient, token?: string) {
  try {
    return await supabase.auth.getClaims(token);
  } catch (error) {
    if (error instanceof SyntaxError) return invalidJwt();
    if (!(error instanceof TypeError)) throw error;

    let candidateToken = token;
    if (!candidateToken) {
      const { data, error: sessionError } = await supabase.auth.getSession();
      if (sessionError) throw sessionError;
      if (!data.session) throw error;
      candidateToken = data.session.access_token;
    }

    if (typeof candidateToken !== "string") return invalidJwt();
    if (!hasMalformedJwtHeaderShape(candidateToken)) throw error;
    return invalidJwt();
  }
}
