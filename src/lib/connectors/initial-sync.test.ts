import { afterEach, describe, expect, it, vi } from "vitest";

import { defaultGmailSyncOptions } from "./gmail/sync";
import { defaultNotionSyncOptions } from "./notion/sync";

import { initialSyncLookbackDays } from "./initial-sync";

afterEach(() => vi.unstubAllEnvs());

describe("initialSyncLookbackDays", () => {
  it("defaults to three days and reads configuration at each call", () => {
    vi.stubEnv("INITIAL_SYNC_LOOKBACK_DAYS", undefined);
    expect(initialSyncLookbackDays()).toBe(3);
    vi.stubEnv("INITIAL_SYNC_LOOKBACK_DAYS", "14");
    expect(initialSyncLookbackDays()).toBe(14);
    expect(defaultGmailSyncOptions().lookbackDays).toBe(14);
    expect(defaultNotionSyncOptions().lookbackDays).toBe(14);
  });

  it.each(["1", "3", "14", "30"])("accepts %s days", (value) => {
    vi.stubEnv("INITIAL_SYNC_LOOKBACK_DAYS", value);
    expect(initialSyncLookbackDays()).toBe(Number(value));
  });

  it.each(["", "0", "-1", "31", "1.5", "14days", " 14", "14 ", "01", "1e1", "Infinity", "99999999999999999999"])("falls back safely for %s", (value) => {
    vi.stubEnv("INITIAL_SYNC_LOOKBACK_DAYS", value);
    expect(initialSyncLookbackDays()).toBe(3);
  });
});
