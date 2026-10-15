import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";

import { BRIDGE_DEVICE_NAME_MAX } from "@/lib/api/contract";

import { normalizeDeviceName, saveBridgeDeviceName } from "./device-name";

const points = (value: string) => Array.from(value).length;
const bridgeId = "10000000-0000-4000-8000-0000000000b1";
const userId = "10000000-0000-4000-8000-000000000001";

describe("normalizeDeviceName (N1)", () => {
  it("한도는 64 코드 포인트다", () => {
    expect(BRIDGE_DEVICE_NAME_MAX).toBe(64);
  });

  it("이미 깨끗한 이름은 그대로 돌려준다", () => {
    for (const name of ["Studio", "Test Mac", "Test Mac mini (2)", "스튜디오 맥", "A", "Mac-1_a.b"]) expect(normalizeDeviceName(name)).toBe(name);
  });

  it("NFC로 합친다", () => {
    expect(normalizeDeviceName("Café")).toBe("Café");
    expect(normalizeDeviceName("한")).toBe("한");
  });

  it("제어 문자(Cc)를 지운다", () => {
    expect(normalizeDeviceName("Test\u0007Mac")).toBe("TestMac");
    expect(normalizeDeviceName("Test\u0000Mac\u007f")).toBe("TestMac");
    expect(normalizeDeviceName("Test\u009bMac")).toBe("TestMac");
  });

  it("양방향 제어 · 폭 없는 문자 · 서식 문자(Cf)를 지운다", () => {
    for (const mark of ["‪", "‫", "‬", "‭", "‮", "⁦", "⁧", "⁨", "⁩", "​", "‌", "‍", "‎", "‏", "⁠", "﻿", "­"]) {
      expect(normalizeDeviceName(`Test${mark}Mac`), `U+${mark.codePointAt(0)!.toString(16)}`).toBe("TestMac");
    }
    expect(normalizeDeviceName("‮Mac‬")).toBe("Mac");
    expect(normalizeDeviceName("a ​ b")).toBe("a b");
  });

  it("짝 없는 서로게이트 절반을 지운다", () => {
    expect(normalizeDeviceName("a\ud800b")).toBe("ab");
    expect(normalizeDeviceName("a\udc00b")).toBe("ab");
  });

  it("공백 덩어리를 공백 하나로, 앞뒤는 지운다 (탭 · 줄바꿈 · 폭 있는 공백 포함)", () => {
    expect(normalizeDeviceName("  Test   Mac  ")).toBe("Test Mac");
    expect(normalizeDeviceName("Test \t \n\r Mac")).toBe("Test Mac");
    expect(normalizeDeviceName(" Test　 Mac ")).toBe("Test Mac");
  });

  it("빈 값 · 공백만 · 제어 문자만 · 문자열이 아닌 값은 null", () => {
    for (const value of ["", " ", " \t\n ", "\u0007", "‮‬", "​​", "\ud800"]) expect(normalizeDeviceName(value), JSON.stringify(value)).toBeNull();
    expect(normalizeDeviceName(undefined)).toBeNull();
    expect(normalizeDeviceName(null)).toBeNull();
    expect(normalizeDeviceName(42 as unknown as string)).toBeNull();
  });

  it("64 코드 포인트까지만 남긴다", () => {
    expect(normalizeDeviceName("a".repeat(64))).toBe("a".repeat(64));
    expect(normalizeDeviceName("a".repeat(65))).toBe("a".repeat(64));
    expect(normalizeDeviceName("a".repeat(500))).toBe("a".repeat(64));
    expect(points(normalizeDeviceName("한".repeat(100))!)).toBe(64);
    expect(points(normalizeDeviceName("\u{1f34e}".repeat(100))!)).toBe(64);
  });

  it("글자소(이모지 조합 · 결합 문자) 중간을 자르지 않는다", () => {
    const thumbs = "\u{1f44d}\u{1f3fd}"; // 엄지 + 피부색: 코드 포인트 둘, 글자소 하나
    expect(normalizeDeviceName("a".repeat(62) + thumbs)).toBe("a".repeat(62) + thumbs);
    expect(normalizeDeviceName("a".repeat(63) + thumbs)).toBe("a".repeat(63));
    const combined = "q́"; // 합쳐지는 글자가 없는 결합 문자
    expect(normalizeDeviceName("a".repeat(62) + combined)).toBe("a".repeat(62) + combined);
    expect(normalizeDeviceName("a".repeat(63) + combined)).toBe("a".repeat(63));
    expect(normalizeDeviceName("a".repeat(63) + combined + "bbb")).toBe("a".repeat(63));
  });

  it("자른 끝이 공백이면 다시 지운다", () => {
    expect(normalizeDeviceName("a".repeat(63) + " b")).toBe("a".repeat(63));
  });

  it("64 코드 포인트보다 큰 글자소 하나로 시작하면 null이다 (글자소를 자르지 않는다)", () => {
    expect(normalizeDeviceName("a" + "́".repeat(80))).toBeNull();
  });

  it("결과는 항상 DB CHECK 모양이다: 1–64 코드 포인트 · 앞뒤 공백 없음 · 제어 문자 없음", () => {
    const nasty = ["  ‮ Mac\u0000 ", "a".repeat(70) + "  ", "\t​ x ​\t", "\u{1f34e} " + "b".repeat(80), "x\u0085y", "  z"];
    for (const raw of nasty) {
      const name = normalizeDeviceName(raw);
      expect(name, JSON.stringify(raw)).not.toBeNull();
      expect(points(name!)).toBeGreaterThanOrEqual(1);
      expect(points(name!)).toBeLessThanOrEqual(64);
      expect(name).toBe(name!.trim());
      expect(name).not.toMatch(/[\p{Cc}\p{Cf}\p{Cs}]/u);
      expect(name).not.toMatch(/\s{2,}/u);
    }
  });
});

describe("saveBridgeDeviceName", () => {
  afterEach(() => vi.restoreAllMocks());
  const client = (rpc: ReturnType<typeof vi.fn>) => ({ rpc }) as unknown as SupabaseClient;
  const ok = () => vi.fn<(name: string, args?: unknown) => unknown>(() => ({ throwOnError: async () => ({ data: { status: "updated" } }) }));

  it("정규화한 값으로 set_bridge_device_name을 한 번 부른다", async () => {
    const rpc = ok();
    await saveBridgeDeviceName(client(rpc), { userId, bridgeId, deviceName: "  Studio ‮ " });
    expect(rpc.mock.calls).toEqual([["set_bridge_device_name", { p_user_id: userId, p_bridge_id: bridgeId, p_device_name: "Studio" }]]);
  });

  it("이름이 없거나 정규화하면 비면 부르지 않는다", async () => {
    const rpc = ok();
    for (const deviceName of [undefined, "", "   ", "‮​"]) await saveBridgeDeviceName(client(rpc), { userId, bridgeId, deviceName });
    expect(rpc).not.toHaveBeenCalled();
  });

  it("실패는 삼키고 사건 이름만 남긴다: 이름 · id를 로그에 싣지 않는다", async () => {
    const secretName = "WATCH-NAME-Studio";
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const rpc = vi.fn<(name: string, args?: unknown) => unknown>(() => ({ throwOnError: async () => { throw new Error(`write failed for ${secretName} ${bridgeId}`); } }));
    await expect(saveBridgeDeviceName(client(rpc), { userId, bridgeId, deviceName: secretName })).resolves.toBeUndefined();
    expect(error.mock.calls).toEqual([[JSON.stringify({ event: "bridge_device_name_failed" })]]);
    const text = JSON.stringify(error.mock.calls);
    expect(text).not.toContain(secretName);
    expect(text).not.toContain(bridgeId);
    expect(text).not.toContain(userId);
  });
});
