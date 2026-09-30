import { describe, expect, it, vi } from "vitest";

import { readAll } from "./read-all";

describe("readAll", () => {
  it("reads inclusive 1000-row pages until the final partial page", async () => {
    const page = vi.fn(async (from: number, to: number) => ({
      data: from === 0 && to === 999 ? Array.from({ length: 1000 }, (_, index) => `${from + index}`) : ["1000"],
      error: null,
    }));

    const rows = await readAll<string>(page);

    expect(page.mock.calls).toEqual([[0, 999], [1000, 1999]]);
    expect(rows).toHaveLength(1001);
    expect(rows[rows.length - 1]).toBe("1000");
  });

  it("throws the original page error", async () => {
    const error = new Error("database unavailable");

    await expect(readAll(() => Promise.resolve({ data: null, error }))).rejects.toBe(error);
  });
});
