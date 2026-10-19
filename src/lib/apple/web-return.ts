import { appleReturnFormSchema, appleReturnStateSchema } from "@/lib/api/contract";

// Mac의 Apple 웹 로그인 중계 (POST /api/v1/apple/return)가 앱으로 돌려줄 주소를 만든다. 순수 함수라 저장 · 기록 · 외부 호출이 없다.
// Developer ID Mac 앱은 앱 안 Apple 로그인을 쓸 수 없어(권한을 받지 못한다) 브라우저 창으로 Apple 웹 로그인을 하는데,
// Apple은 return URL로 https 주소만 허락하고 form_post로 보낸다. 그 결과를 앱(ASWebAuthenticationSession)이 받을 수 있는 주소로 넘긴다.
// 목적지는 상수 하나다: 어떤 입력도 다른 주소로 보낼 수 없다 (열린 리다이렉트 0). 값은 모두 퍼센트 인코딩해 쿼리 값으로만 싣는다.
// 토큰 · code · 이메일은 이 함수 밖으로 새지 않는다: 로그에 남기지 않는다.

/** 앱이 받는 주소(앱 URL scheme `taskforce` + 경로). 앱은 자기 ASWebAuthenticationSession 안에서 자기가 만든 state일 때만 쓴다 */
export const APPLE_APP_CALLBACK = "taskforce://auth/apple";

const INVALID_RESPONSE = "invalid_response";

function location(params: [string, string][]): string {
  return `${APPLE_APP_CALLBACK}?${params.map(([key, value]) => `${key}=${encodeURIComponent(value)}`).join("&")}`;
}

/** 읽는 이름이 두 번 오면(파라미터 오염) 하나로 정할 수 없다: 값은 첫 번째로 두고 어느 이름이 겹쳤는지 알린다 */
function readForm(body: string): { values: Record<string, string>; repeated: Set<string> } {
  const values: Record<string, string> = {};
  const repeated = new Set<string>();
  for (const [key, value] of new URLSearchParams(body)) {
    if (Object.hasOwn(values, key)) repeated.add(key);
    else values[key] = value;
  }
  return { values, repeated };
}

/**
 * form 본문(application/x-www-form-urlencoded) → 앱으로 보낼 주소.
 * - state가 없거나 모양이 틀리면 state 없이 `?error=invalid_response` (틀린 state를 되돌려 싣지 않는다)
 * - error가 있으면 `?state&error` (같이 온 code · id_token은 싣지 않는다)
 * - code · id_token이 하나도 없거나, 길이가 넘치거나, 같은 이름이 두 번 오면 `?state&error=invalid_response`
 * - 그 밖에는 로그인이면 `?state&id_token`(code는 싣지 않는다), 재확인(code만)이면 `?state&code`. user(첫 로그인 때 오는 이름 · 이메일 JSON)는 받아도 버린다.
 */
export function appleReturnLocation(body: string): string {
  const { values, repeated } = readForm(body);
  const state = appleReturnStateSchema.safeParse(values.state);
  if (!state.success || repeated.has("state")) return location([["error", INVALID_RESPONSE]]);

  const form = appleReturnFormSchema.safeParse(values);
  if (!form.success || ["code", "id_token", "error"].some((key) => repeated.has(key))) return location([["state", state.data], ["error", INVALID_RESPONSE]]);
  const { code, id_token: idToken, error } = form.data;
  if (error) return location([["state", state.data], ["error", error]]);
  if (!code && !idToken) return location([["state", state.data], ["error", INVALID_RESPONSE]]);

  const params: [string, string][] = [["state", state.data]];
  // 로그인(id_token이 있음)에서는 앱이 code를 쓰지 않는다: 쓰지 않는 code를 앱 주소에 남기지 않는다. 재확인(code만)은 code를 싣는다
  if (idToken) params.push(["id_token", idToken]);
  else if (code) params.push(["code", code]);
  return location(params);
}
