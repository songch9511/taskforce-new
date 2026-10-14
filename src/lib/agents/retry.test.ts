import { describe, expect, it, vi } from "vitest";

import { retryOnConflict } from "./retry";

// 롤백된 경합(40001 직렬화 실패 · 40P01 교착 · 55P03 NOWAIT 잠금 경합)만 같은 호출을 다시 한다: 최대 2번 다시 = 모두 3번 시도 (검토 반영 9-2).
const conflict = (code: string) => Object.assign(new Error("conflict"), { code });

describe("retryOnConflict", () => {
  it("처음에 성공하면 한 번만 부른다", async () => {
    const call = vi.fn(async () => "ok");
    expect(await retryOnConflict(call)).toBe("ok");
    expect(call).toHaveBeenCalledTimes(1);
  });

  it.each(["40001", "40P01", "55P03"])("%s는 두 번 실패해도 세 번째에 성공하면 그 결과를 돌려준다", async (code) => {
    const call = vi.fn().mockRejectedValueOnce(conflict(code)).mockRejectedValueOnce(conflict(code)).mockResolvedValueOnce("ok");
    expect(await retryOnConflict(call)).toBe("ok");
    expect(call).toHaveBeenCalledTimes(3);
  });

  it.each(["40001", "40P01", "55P03"])("%s가 세 번 모두 나오면 던진다 (handler가 409 busy_retry로 바꾼다)", async (code) => {
    const call = vi.fn(async () => { throw conflict(code); });
    await expect(retryOnConflict(call)).rejects.toMatchObject({ code });
    expect(call).toHaveBeenCalledTimes(3);
  });

  it("섞여 나와도 세 번까지만 (40001 → 40P01 → 55P03 → 던짐)", async () => {
    const call = vi.fn().mockRejectedValueOnce(conflict("40001")).mockRejectedValueOnce(conflict("40P01")).mockRejectedValueOnce(conflict("55P03")).mockResolvedValue("never");
    await expect(retryOnConflict(call)).rejects.toMatchObject({ code: "55P03" });
    expect(call).toHaveBeenCalledTimes(3);
  });

  it.each([["XX000"], ["23505"], ["22023"], [undefined]])("다른 오류(%s)는 다시 하지 않는다", async (code) => {
    const call = vi.fn(async () => { throw code ? conflict(code) : new Error("plain"); });
    await expect(retryOnConflict(call)).rejects.toThrow();
    expect(call).toHaveBeenCalledTimes(1);
  });

  it("객체가 아닌 던짐도 그대로 던진다", async () => {
    const call = vi.fn(async () => { throw "text"; });
    await expect(retryOnConflict(call)).rejects.toBe("text");
    expect(call).toHaveBeenCalledTimes(1);
  });
});
