import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// /lab(내부 시험대)은 운영자(ADMIN_EMAILS)만 연다. 그 밖의 사용자는 404, 로그인하지 않았으면 /login (처리방침 10장).

const mocks = vi.hoisted(() => ({
  getVerifiedClaims: vi.fn(),
  createClient: vi.fn(),
  nowList: vi.fn(),
  redirect: vi.fn((path: string) => {
    throw new Error(`redirect:${path}`);
  }),
  notFound: vi.fn(() => {
    throw new Error("notFound");
  }),
}));

vi.mock("server-only", () => ({}));
vi.mock("next/navigation", () => ({ redirect: mocks.redirect, notFound: mocks.notFound }));
vi.mock("@/lib/supabase/claims", () => ({ getVerifiedClaims: mocks.getVerifiedClaims }));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createClient }));
vi.mock("@/lib/actions/service", () => ({ nowList: mocks.nowList }));

import LabLayout from "./layout";
import LabPage from "./page";

const USER_ID = "11111111-1111-4111-8111-111111111111";

// 어떤 메서드를 이어 불러도 자기를 돌려주고, await하면 빈 결과가 되는 Supabase 쿼리 대역
function emptyQuery(): object {
  const query: object = new Proxy(
    {},
    { get: (_target, prop) => (prop === "then" ? (resolve: (value: unknown) => void) => resolve({ data: null, error: null }) : () => query) },
  );
  return query;
}

const supabase = { from: vi.fn(() => emptyQuery()) };

function signedInAs(email: string | undefined) {
  mocks.getVerifiedClaims.mockResolvedValue({ data: { claims: { sub: USER_ID, ...(email === undefined ? {} : { email }) } }, error: null });
}

function signedOut() {
  mocks.getVerifiedClaims.mockResolvedValue({ data: null, error: new Error("Auth session missing") });
}

const layoutProps = { children: "시험대", params: Promise.resolve({}) } as unknown as LayoutProps<"/lab">;
const pageProps = { searchParams: Promise.resolve({}) };

beforeEach(() => {
  vi.stubEnv("ADMIN_EMAILS", "ops@example.test, second-ops@example.test");
  mocks.createClient.mockResolvedValue(supabase);
  mocks.nowList.mockResolvedValue({ now: [], confirmations: [] });
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.clearAllMocks();
});

describe("/lab 레이아웃", () => {
  it("운영자면 하위 화면을 그대로 보여준다 (대소문자 무시)", async () => {
    signedInAs("Ops@Example.test");
    await expect(LabLayout(layoutProps)).resolves.toBe("시험대");
    expect(mocks.notFound).not.toHaveBeenCalled();
  });

  it("운영자가 아닌 사용자에게는 없는 페이지(404)", async () => {
    signedInAs("user@example.test");
    await expect(LabLayout(layoutProps)).rejects.toThrow("notFound");
  });

  it("이메일이 없는 계정도 404", async () => {
    signedInAs(undefined);
    await expect(LabLayout(layoutProps)).rejects.toThrow("notFound");
  });

  it("ADMIN_EMAILS가 비어 있으면 아무도 열지 못한다", async () => {
    vi.stubEnv("ADMIN_EMAILS", "");
    signedInAs("ops@example.test");
    await expect(LabLayout(layoutProps)).rejects.toThrow("notFound");
  });

  it("로그인하지 않았으면 지금처럼 /login으로 보낸다", async () => {
    signedOut();
    await expect(LabLayout(layoutProps)).rejects.toThrow("redirect:/login");
    expect(mocks.notFound).not.toHaveBeenCalled();
  });
});

// 레이아웃은 페이지 렌더를 멈추지 못한다(Next 인증 가이드). 페이지도 데이터를 읽기 전에 스스로 막아야 한다.
describe("/lab 페이지", () => {
  it("운영자면 화면을 만든다", async () => {
    signedInAs("second-ops@example.test");
    await expect(LabPage(pageProps)).resolves.toBeTruthy();
    expect(supabase.from).toHaveBeenCalledWith("sources");
    expect(mocks.nowList).toHaveBeenCalled();
  });

  it("운영자가 아니면 아무 데이터도 읽지 않고 404", async () => {
    signedInAs("user@example.test");
    await expect(LabPage(pageProps)).rejects.toThrow("notFound");
    expect(supabase.from).not.toHaveBeenCalled();
    expect(mocks.nowList).not.toHaveBeenCalled();
  });

  it("로그인하지 않았으면 /login으로 보내고 데이터를 읽지 않는다", async () => {
    signedOut();
    await expect(LabPage(pageProps)).rejects.toThrow("redirect:/login");
    expect(mocks.notFound).not.toHaveBeenCalled();
    expect(supabase.from).not.toHaveBeenCalled();
  });
});
