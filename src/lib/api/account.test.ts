import { describe, expect, it, vi } from "vitest";

import { handleDeleteAccount, type DeleteAccountDeps } from "./account";
import { apiErrorSchema, deleteAccountResponseSchema } from "./contract";

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
