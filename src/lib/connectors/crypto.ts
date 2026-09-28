import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

// 외부 서비스 토큰을 DB에 넣기 전에 암호화한다 (AES-256-GCM).
// 키는 CONNECTOR_TOKEN_KEY(32바이트를 base64로)에만 두고, DB가 새어도 토큰은 읽히지 않게 한다.

const VERSION = "v1";

export function parseTokenKey(base64: string | undefined): Buffer {
  const key = base64 ? Buffer.from(base64, "base64") : Buffer.alloc(0);
  if (key.length !== 32) {
    throw new Error("CONNECTOR_TOKEN_KEY는 32바이트를 base64로 인코딩한 값이어야 합니다 (openssl rand -base64 32).");
  }
  return key;
}

export function encryptSecret(plaintext: string, key: Buffer): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return [VERSION, iv.toString("base64"), cipher.getAuthTag().toString("base64"), encrypted.toString("base64")].join(".");
}

export function decryptSecret(sealed: string, key: Buffer): string {
  const [version, iv, tag, data] = sealed.split(".");
  if (version !== VERSION || !iv || !tag || !data) throw new Error("알 수 없는 암호문 형식");
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(iv, "base64"));
  decipher.setAuthTag(Buffer.from(tag, "base64"));
  return Buffer.concat([decipher.update(Buffer.from(data, "base64")), decipher.final()]).toString("utf8");
}
