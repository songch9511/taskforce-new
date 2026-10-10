import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { embed } from "@/lib/ai/embed";
import { processSource } from "@/lib/sources/process";

import { ingestDeps, loadIdentity, saveConnection } from "./store";
import type { Connection, IngestItem } from "./types";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/sources/process", () => ({ processSource: vi.fn(async () => ({ needsConfirmation: [] })), processTaskSource: vi.fn() }));
vi.mock("@/lib/ai/embed", async (original) => ({
  ...(await original<typeof import("@/lib/ai/embed")>()),
  embed: vi.fn(async (_config: unknown, texts: string[]) => ({ vectors: texts.map(() => Array.from({ length: 1536 }, () => 0)) })),
}));

// 맥락층(B1)이 기존 연결 경로에 붙인 것: loadIdentity의 신원 링크 합치기, 수집 뒤 조각 만들기, 연결 결과의 oauth 링크.
// gate(MEMORY_ENABLED · SOURCE_CHUNKS_ENABLED)가 꺼져 있으면(기본) 기존 수집 · 처리와 똑같다: 새 표를 읽지도 쓰지도 않고 임베딩을 부르지 않는다.

type Call = { kind: "from" | "rpc"; name: string; ops: { op: string; args: unknown[] }[] };

/** 모든 호출을 기록하는 가짜 service role 클라이언트. results[이름]이 await 결과의 data다 */
function recordingAdmin(results: Record<string, unknown> = {}, email = "login@example.com") {
  const calls: Call[] = [];
  const chain = (call: Call): unknown =>
    new Proxy(
      {},
      {
        get: (_target, prop: string) => {
          if (prop === "then") {
            return (resolve: (value: unknown) => void, reject: (error: unknown) => void) =>
              Promise.resolve({ data: results[call.name] ?? null, error: null }).then(resolve, reject);
          }
          return (...args: unknown[]) => {
            call.ops.push({ op: prop, args });
            return chain(call);
          };
        },
      },
    );
  const admin = {
    auth: { admin: { getUserById: async (id: string) => ({ data: { user: { id, email, user_metadata: {} } } }) } },
    from: (name: string) => {
      const call: Call = { kind: "from", name, ops: [] };
      calls.push(call);
      return chain(call);
    },
    rpc: (name: string, args: unknown) => {
      const call: Call = { kind: "rpc", name, ops: [{ op: "args", args: [args] }] };
      calls.push(call);
      return chain(call);
    },
  } as unknown as SupabaseClient;
  return { admin, calls, names: () => calls.map((c) => c.name) };
}

const profile = { display_name: "Me", aliases: [], emails: ["work@company.dev"], ai_consent_at: "2026-10-01T00:00:00Z" };
const connection: Connection = { id: "n1", userId: "u1", provider: "notion", settings: {}, syncCursor: null };
const item: IngestItem = {
  externalId: "page-1",
  externalVersion: "v1",
  kind: "doc",
  title: "출시 준비",
  text: "출시 준비 회의: 디자인 확정 뒤 개발을 시작한다.\n\n".repeat(120),
  occurredAt: new Date("2026-10-01T00:00:00Z"),
  lastEditedAt: new Date("2026-10-01T00:00:00Z"),
  externalUrl: "https://notion.so/page-1",
  writtenByMe: null,
};

beforeEach(() => {
  vi.clearAllMocks();
});

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("gate 꺼짐 회귀: 수집 · 처리는 지금과 같다", () => {
  it("ingestDeps.process는 원문 처리만 하고 신원 링크 · 조각 · 임베딩을 부르지 않는다", async () => {
    const { admin, names } = recordingAdmin({ profiles: profile, connections: [{ settings: { email: "me@company.dev" } }] });
    await ingestDeps(admin).process(connection, "s1", item);
    expect(processSource).toHaveBeenCalledTimes(1);
    expect(vi.mocked(processSource).mock.calls[0][2]).toMatchObject({
      text: item.text,
      identity: { name: "Me", emails: ["login@example.com", "work@company.dev", "me@company.dev"] },
    });
    expect(names().sort()).toEqual(["connections", "profiles"]);
    expect(embed).not.toHaveBeenCalled();
  });

  it("saveConnection은 신원 링크를 쓰지 않는다", async () => {
    vi.stubEnv("CONNECTOR_TOKEN_KEY", Buffer.alloc(32, 1).toString("base64"));
    const { admin, names } = recordingAdmin({ connections: { id: "c1", settings: null } });
    await saveConnection(admin, { userId: "u1", provider: "slack", externalAccountId: "T1:U1", displayName: "Acme", token: { access_token: "x" } });
    expect(names()).toEqual(["connections", "connection_secrets"]);
  });
});

describe("gate 켜짐", () => {
  it("MEMORY_ENABLED: loadIdentity가 신원 링크를 합친다 (추정 · 공용은 올리지 않고, 공용 주소는 연결 설정 주소에서도 뺀다)", async () => {
    const { admin } = recordingAdmin({
      profiles: profile,
      connections: [{ settings: { email: "me@company.dev" } }, { settings: { email: "team@company.dev" } }],
      identity_links: [
        { provider: "gmail", account_ref: "sub-2", email: "me@home.dev", verified_via: "oauth", shared_account: false },
        { provider: "gmail", account_ref: "maybe", email: "maybe@company.dev", verified_via: "inferred", shared_account: false },
        { provider: "gmail", account_ref: "team", email: "team@company.dev", verified_via: "user_confirmed", shared_account: true },
      ],
    });
    const identity = await loadIdentity(admin, "u1", { MEMORY_ENABLED: "true" });
    expect(identity.emails).toEqual(["login@example.com", "work@company.dev", "me@company.dev", "me@home.dev"]);
    // 꺼져 있으면 링크를 읽지 않는다
    const off = recordingAdmin({ profiles: profile, connections: [{ settings: { email: "team@company.dev" } }] });
    expect((await loadIdentity(off.admin, "u1", {})).emails).toEqual(["login@example.com", "work@company.dev", "team@company.dev"]);
    expect(off.names()).not.toContain("identity_links");
  });

  it("MEMORY_ENABLED: 신원 링크를 읽지 못하면 넓히지 않고 실패한다 — 공용으로 확인한 연결 주소가 나로 돌아오지 않고, 원문 처리는 시작하지 않는다(대기로 남아 재처리)", async () => {
    const connections = [{ settings: { email: "me@example.com" } }, { settings: { email: "team@example.com" } }];
    const links = [{ provider: "gmail", account_ref: "team", email: "team@example.com", verified_via: "user_confirmed", shared_account: true }];
    // 정상: 공용으로 확인한 주소는 나가 아니다
    const ok = recordingAdmin({ profiles: profile, connections, identity_links: links });
    expect((await loadIdentity(ok.admin, "u1", { MEMORY_ENABLED: "true" })).emails).toEqual(["login@example.com", "work@company.dev", "me@example.com"]);

    // 링크 읽기 실패: 링크 없이(= 공용 제외를 잃고) 넓히지 않는다
    const broken = recordingAdmin({ profiles: profile, connections });
    const brokenAdmin = {
      auth: (broken.admin as unknown as { auth: unknown }).auth,
      from: (name: string) => {
        if (name !== "identity_links") return broken.admin.from(name);
        const failing: Record<string, unknown> = {};
        for (const op of ["select", "eq"]) failing[op] = () => failing;
        failing.throwOnError = () => Promise.reject(new Error("identity_links read failed"));
        return failing;
      },
    } as unknown as SupabaseClient;
    await expect(loadIdentity(brokenAdmin, "u1", { MEMORY_ENABLED: "true" })).rejects.toThrow(/identity_links read failed/);
    // 수집: 처리를 시작하지 않고 실패한다 (원문은 대기로 남아 sources/retry.ts가 다시 처리한다)
    vi.stubEnv("MEMORY_ENABLED", "true");
    await expect(ingestDeps(brokenAdmin).process(connection, "s1", item)).rejects.toThrow(/identity_links read failed/);
    expect(processSource).not.toHaveBeenCalled();
    vi.unstubAllEnvs();
    // gate 꺼짐: 링크를 읽지 않고 지금과 같다
    expect((await loadIdentity(brokenAdmin, "u1", {})).emails).toEqual(["login@example.com", "work@company.dev", "me@example.com", "team@example.com"]);
  });

  it("SOURCE_CHUNKS_ENABLED: 처리한 원문의 조각을 동의 확인 뒤 임베딩해 replace_source_chunks로 넣는다. Slack 원문은 만들지 않는다", async () => {
    vi.stubEnv("SOURCE_CHUNKS_ENABLED", "true");
    vi.stubEnv("OPENROUTER_API_KEY", "test-key");
    const { admin, calls, names } = recordingAdmin({ profiles: profile, connections: [], replace_source_chunks: { status: "replaced", chunks: 3 } });
    await ingestDeps(admin).process(connection, "s1", item);
    expect(names()).toContain("replace_source_chunks");
    const args = calls.find((c) => c.name === "replace_source_chunks")!.ops[0].args[0] as { p_user_id: string; p_source_id: string; p_texts: string[] };
    expect(args).toMatchObject({ p_user_id: "u1", p_source_id: "s1" });
    expect(args.p_texts.join("").replace(/\s/g, "")).toBe(item.text.replace(/\s/g, ""));
    expect(embed).toHaveBeenCalledTimes(1);

    vi.mocked(embed).mockClear();
    const slack = recordingAdmin({ profiles: profile, connections: [] });
    await ingestDeps(slack.admin).process({ ...connection, provider: "slack" }, "s2", item);
    expect(slack.names()).not.toContain("replace_source_chunks");
    expect(embed).not.toHaveBeenCalled();
  });

  it("MEMORY_ENABLED: saveConnection이 연결 결과의 oauth 링크를 남긴다 (Notion 워크스페이스 연결은 사람 계정이 아니라 남기지 않는다)", async () => {
    vi.stubEnv("CONNECTOR_TOKEN_KEY", Buffer.alloc(32, 1).toString("base64"));
    vi.stubEnv("MEMORY_ENABLED", "true");
    const google = recordingAdmin({ connections: { id: "c1", settings: null } });
    await saveConnection(google.admin, { userId: "u1", provider: "gmail", externalAccountId: "sub-1", displayName: "Me@Gmail.com", token: {} });
    const upsert = google.calls.filter((c) => c.name === "identity_links").flatMap((c) => c.ops).find((o) => o.op === "upsert")!.args;
    expect(upsert[0]).toEqual({ user_id: "u1", provider: "gmail", account_ref: "sub-1", email: "me@gmail.com", connection_id: "c1", verified_via: "oauth" });
    const notion = recordingAdmin({ connections: { id: "c2", settings: null } });
    await saveConnection(notion.admin, { userId: "u1", provider: "notion", externalAccountId: "workspace-1", displayName: "Acme", token: {} });
    expect(notion.names()).not.toContain("identity_links");
  });
});
