import { randomBytes } from "node:crypto";

import { describe, expect, it } from "vitest";

import { decryptSecret, encryptSecret, parseTokenKey } from "./crypto";

const key = randomBytes(32);

describe("토큰 암호화", () => {
  it("암호화한 값을 되돌리고, 같은 값도 매번 다른 암호문이 된다", () => {
    const a = encryptSecret("secret_abc", key);
    const b = encryptSecret("secret_abc", key);
    expect(a).not.toBe(b);
    expect(a).not.toContain("secret_abc");
    expect(decryptSecret(a, key)).toBe("secret_abc");
  });

  it("다른 키나 변조된 암호문은 풀리지 않는다", () => {
    const sealed = encryptSecret("secret_abc", key);
    expect(() => decryptSecret(sealed, randomBytes(32))).toThrow();
    const parts = sealed.split(".");
    parts[3] = Buffer.from("tampered").toString("base64");
    expect(() => decryptSecret(parts.join("."), key)).toThrow();
  });

  it("키는 32바이트여야 한다", () => {
    expect(parseTokenKey(key.toString("base64"))).toHaveLength(32);
    expect(() => parseTokenKey(undefined)).toThrow(/CONNECTOR_TOKEN_KEY/);
    expect(() => parseTokenKey(randomBytes(16).toString("base64"))).toThrow();
  });
});
