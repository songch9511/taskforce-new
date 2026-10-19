import { describe, expect, it, vi } from "vitest";

import { DELETE } from "@/app/api/v1/account/route";

import { handleDeleteAccount, type DeleteAccountDeps } from "./account";
import { apiErrorSchema, deleteAccountResponseSchema } from "./contract";

// route 배선 시험(맨 아래)이 쓰는 가짜: 관리자 클라이언트 · 인증 · 결제 · 연동 폐기 · Apple 폐기. 실제 Supabase · Apple에 닿지 않는다.
const wiring = vi.hoisted(() => ({
  getUserById: vi.fn(),
  deleteUser: vi.fn(async () => ({ error: null })),
  revokeApple: vi.fn(async () => "revoked"),
}));
vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: () => ({ auth: { admin: { getUserById: wiring.getUserById, deleteUser: wiring.deleteUser } } }) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: async () => ({ user: { id: "user-1" } }) }));
vi.mock("@/lib/billing/service", () => ({ cancelBeforeDeletion: async () => "deletion-token", rollbackDeletion: vi.fn() }));
vi.mock("@/lib/connectors/registry", () => ({ revokeConnectorTokens: async () => ({ failed: 0 }) }));
vi.mock("@/lib/apple/sign-in", () => ({
  appleSignInConfigFromEnv: () => ({ teamId: "T", keyId: "K", key: null, clientId: "dev.taskforcelabs.taskforce", servicesId: "dev.taskforcelabs.taskforce.signin" }),
  revokeAppleSignIn: wiring.revokeApple,
}));

type User = { id: string };

const request = () => new Request("http://localhost/api/v1/account", { method: "DELETE" });

function deps(user: User | null, deleteUser: DeleteAccountDeps<User>["deleteUser"] = async () => {}) {
  const deleted: string[] = [];
  const d: DeleteAccountDeps<User> = {
    authenticate: async () => user,
    deleteUser: async (userId) => {
      await deleteUser(userId);
      deleted.push(userId);
    },
  };
  return { d, deleted };
}

describe("account API", () => {
  it("로그인한 사용자 본인 계정을 지운다", async () => {
    const { d, deleted } = deps({ id: "user-1" });
    const response = await handleDeleteAccount(request(), d);
    expect(response.status).toBe(200);
    expect(deleteAccountResponseSchema.parse(await response.json())).toEqual({ deleted: true });
    expect(deleted).toEqual(["user-1"]);
  });

  it("로그인하지 않았으면 401이고 아무것도 지우지 않는다", async () => {
    const { d, deleted } = deps(null);
    const response = await handleDeleteAccount(request(), d);
    expect(response.status).toBe(401);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("unauthorized");
    expect(deleted).toEqual([]);
  });

  it("삭제가 실패하면 500, 로그에는 오류 메시지만 남긴다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { d } = deps({ id: "user-1" }, async () => {
      throw new Error("Database error deleting user");
    });
    const response = await handleDeleteAccount(request(), d);
    expect(response.status).toBe(500);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("internal_error");
    expect(log).toHaveBeenCalledWith("계정 삭제 실패:", "Database error deleting user");
    log.mockRestore();
  });
});

describe("account API — 토큰 폐기", () => {
  const del = (body?: unknown) =>
    new Request("http://localhost/api/v1/account", { method: "DELETE", body: body === undefined ? undefined : JSON.stringify(body) });

  function revokingDeps(options: { connectors?: () => Promise<void>; apple?: () => Promise<void> } = {}) {
    const steps: string[] = [];
    const codes: (string | undefined)[] = [];
    const clients: string[] = [];
    const d: DeleteAccountDeps<User> = {
      authenticate: async () => ({ id: "user-1" }),
      revokeConnectorTokens: async (user) => {
        steps.push(`connectors:${user.id}`);
        await options.connectors?.();
      },
      revokeAppleToken: async (user, code, client) => {
        steps.push(`apple:${user.id}`);
        codes.push(code);
        clients.push(client);
        await options.apple?.();
      },
      deleteUser: async (userId) => {
        steps.push(`delete:${userId}`);
      },
    };
    return { d, steps, codes, clients };
  }

  it("지우기 전에 연동 토큰과 Apple 토큰을 (동시에) 폐기한다 (본문 없이도)", async () => {
    const { d, steps, codes } = revokingDeps();
    const response = await handleDeleteAccount(del(), d);
    expect(response.status).toBe(200);
    expect(steps).toEqual(["connectors:user-1", "apple:user-1", "delete:user-1"]);
    expect(codes).toEqual([undefined]);
  });

  it("폐기 둘을 동시에 시작한다: 연동 폐기가 느려도 Apple 폐기를 기다리게 하지 않는다", async () => {
    let releaseConnectors!: () => void;
    const { d, steps } = revokingDeps({ connectors: () => new Promise<void>((resolve) => (releaseConnectors = resolve)) });
    const pending = handleDeleteAccount(del(), d);
    await vi.waitFor(() => expect(steps).toEqual(["connectors:user-1", "apple:user-1"]));
    releaseConnectors();
    expect((await pending).status).toBe(200);
    expect(steps.at(-1)).toBe("delete:user-1");
  });

  it("폐기가 시간 한도를 넘기면 기다리지 않고 계정을 지운다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { d, steps } = revokingDeps({ apple: () => new Promise<void>(() => {}) });
    const response = await handleDeleteAccount(del(), { ...d, revocationTimeoutMs: 20 });
    expect(response.status).toBe(200);
    expect(steps.at(-1)).toBe("delete:user-1");
    expect(log).toHaveBeenCalledWith("토큰 폐기가 시간 한도를 넘겨 기다리지 않고 계정을 지웁니다.");
    log.mockRestore();
  });

  it("앱이 보낸 Apple authorization code를 넘긴다", async () => {
    const { d, codes } = revokingDeps();
    await handleDeleteAccount(del({ apple_authorization_code: "c123" }), d);
    expect(codes).toEqual(["c123"]);
  });

  it("apple_client를 폐기에 넘긴다: web은 Mac 웹 재확인 code, 생략하면 app(번들 id)", async () => {
    const { d, codes, clients } = revokingDeps();
    await handleDeleteAccount(del({ apple_authorization_code: "c-web", apple_client: "web" }), d);
    await handleDeleteAccount(del({ apple_authorization_code: "c-app", apple_client: "app" }), d);
    await handleDeleteAccount(del({ apple_authorization_code: "c-none" }), d);
    await handleDeleteAccount(del(), d);
    expect(codes).toEqual(["c-web", "c-app", "c-none", undefined]);
    expect(clients).toEqual(["web", "app", "app", "app"]);
  });

  it("apple_client가 app · web 밖의 값이면 400이고 아무것도 폐기 · 삭제하지 않는다", async () => {
    const { d, steps } = revokingDeps();
    for (const apple_client of ["", "WEB", "services", "bundle", 1, null]) {
      expect((await handleDeleteAccount(del({ apple_authorization_code: "c", apple_client }), d)).status).toBe(400);
    }
    expect(steps).toEqual([]);
  });

  it("폐기가 실패해도 계정은 지우고, 로그에는 오류 메시지만 남긴다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { d, steps } = revokingDeps({
      connectors: async () => {
        throw new Error("Notion 토큰 폐기 실패 (500)");
      },
      apple: async () => {
        throw new Error("Apple 토큰 교환 실패 (400)");
      },
    });
    const response = await handleDeleteAccount(del({ apple_authorization_code: "secret-code" }), d);
    expect(response.status).toBe(200);
    expect(steps.at(-1)).toBe("delete:user-1");
    expect(log).toHaveBeenCalledWith("연동 토큰 폐기 실패 (계정 삭제는 계속):", "Notion 토큰 폐기 실패 (500)");
    expect(log).toHaveBeenCalledWith("Apple 토큰 폐기 실패 (계정 삭제는 계속):", "Apple 토큰 교환 실패 (400)");
    expect(JSON.stringify(log.mock.calls)).not.toContain("secret-code");
    log.mockRestore();
  });

  it("잘못된 본문은 400이고 아무것도 폐기 · 삭제하지 않는다", async () => {
    const { d, steps } = revokingDeps();
    expect((await handleDeleteAccount(del({ apple_authorization_code: "" }), d)).status).toBe(400);
    expect(steps).toEqual([]);
  });
});

it("billing cancellation failure preserves identity and connected-service tokens", async () => {
  const { d, deleted } = deps({ id: "user-1" });
  d.beforeDelete = vi.fn(async () => { throw new Error("provider unavailable"); });
  d.revokeConnectorTokens = vi.fn();
  d.revokeAppleToken = vi.fn();
  const response = await handleDeleteAccount(request(), d);
  expect(response.status).toBe(503);
  expect(deleted).toEqual([]);
  expect(d.revokeConnectorTokens).not.toHaveBeenCalled();
  expect(d.revokeAppleToken).not.toHaveBeenCalled();
});

describe("DELETE /api/v1/account route 배선 — Apple 폐기의 client", () => {
  const SUB = "001234.abcdef.0123";
  const call = (body?: unknown) =>
    DELETE(new Request("http://localhost/api/v1/account", { method: "DELETE", body: body === undefined ? undefined : JSON.stringify(body) }));

  function appleUser() {
    wiring.getUserById.mockResolvedValue({ data: { user: { identities: [{ provider: "apple", id: SUB, identity_data: { sub: SUB } }] } } });
  }

  it("apple_client web이면 Services ID client로 폐기한다 (code · sub와 함께)", async () => {
    appleUser();
    wiring.revokeApple.mockClear();
    expect((await call({ apple_authorization_code: "web-code", apple_client: "web" })).status).toBe(200);
    expect(wiring.revokeApple).toHaveBeenCalledTimes(1);
    const [config, code, sub, options] = wiring.revokeApple.mock.calls[0] as unknown as [{ servicesId: string }, string, string, { client: string }];
    expect(config.servicesId).toBe("dev.taskforcelabs.taskforce.signin");
    expect([code, sub, options]).toEqual(["web-code", SUB, { client: "web" }]);
  });

  it("생략하면 app(번들 id)이다: iPhone 앱 안 로그인의 code", async () => {
    appleUser();
    wiring.revokeApple.mockClear();
    await call({ apple_authorization_code: "app-code" });
    const [, code, , options] = wiring.revokeApple.mock.calls[0] as unknown as [unknown, string, string, { client: string }];
    expect([code, options]).toEqual(["app-code", { client: "app" }]);
  });

  it("잘못된 apple_client는 400이고 폐기 · 삭제를 하지 않는다", async () => {
    appleUser();
    wiring.revokeApple.mockClear();
    wiring.deleteUser.mockClear();
    expect((await call({ apple_authorization_code: "c", apple_client: "services" })).status).toBe(400);
    expect(wiring.revokeApple).not.toHaveBeenCalled();
    expect(wiring.deleteUser).not.toHaveBeenCalled();
  });
});
