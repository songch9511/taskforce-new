import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { quotedHistoryStart, quoteInText } from "@/lib/pipeline/text";

import { findLabelErrors, goldenCaseSchema, type GoldenCase } from "./golden";

const base: GoldenCase = {
  id: "t",
  description: "테스트",
  origin: "synthetic",
  user: { name: "나", aliases: [], emails: [] },
  sources: [
    { id: "s1", kind: "meeting", occurred_at: "2025-09-22T10:00:00+09:00", text: "금요일까지  제안서 보내드릴게요" },
  ],
  expected_actions: [
    {
      title: "제안서 발송",
      owner: "me",
      due: "2025-09-26",
      status: "open",
      evidence: [{ source: "s1", quote: "금요일까지 제안서 보내드릴게요" }],
    },
  ],
  must_not_extract: [],
};

describe("findLabelErrors", () => {
  it("공백 차이는 무시하고 인용을 찾는다", () => {
    expect(findLabelErrors(base)).toEqual([]);
  });

  it("원문에 없는 인용을 잡는다", () => {
    const golden = {
      ...base,
      expected_actions: [{ ...base.expected_actions[0], evidence: [{ source: "s1", quote: "월요일까지" }] }],
    };
    expect(findLabelErrors(golden)).toEqual([expect.stringContaining("인용이 원문 s1에 없습니다")]);
  });

  it("없는 source를 가리키면 잡는다", () => {
    const golden = {
      ...base,
      must_not_extract: [{ source: "s9", quote: "x", reason: "INFO_ONLY" as const }],
    };
    expect(findLabelErrors(golden)).toEqual([expect.stringContaining("없는 source")]);
  });

  it("needs_review는 원문 하나 케이스에만 쓸 수 있다", () => {
    const single = { ...base, expected_actions: [{ ...base.expected_actions[0], needs_review: true }] };
    expect(findLabelErrors(single)).toEqual([]);
    const sequence = { ...single, sources: [...base.sources, { ...base.sources[0], id: "s2" }] };
    expect(findLabelErrors(sequence)).toEqual([expect.stringContaining("원문 하나 케이스에만")]);
  });
});

describe("evals/golden", () => {
  it("모든 케이스가 형식에 맞고 라벨 오류가 없다", async () => {
    const dir = path.resolve(import.meta.dirname, "../../../evals/golden");
    const files = (await readdir(dir)).filter((f) => f.endsWith(".json"));
    expect(files.length).toBeGreaterThan(0);

    for (const file of files) {
      const golden = goldenCaseSchema.parse(JSON.parse(await readFile(path.join(dir, file), "utf8")));
      expect(findLabelErrors(golden), file).toEqual([]);
    }
  });

  // docs/go-live/google-integration.md 2-5 · 2-6: Gmail · Meet 어댑터가 만들 본문과 같은 모양인지 (글자 비교는 어댑터 테스트가 한다)
  it("Gmail · Meet 케이스는 어댑터 본문 형식을 따른다", async () => {
    const dir = path.resolve(import.meta.dirname, "../../../evals/golden");
    const files = (await readdir(dir)).filter((f) => f.endsWith(".json"));
    const cases = await Promise.all(files.map(async (f) => goldenCaseSchema.parse(JSON.parse(await readFile(path.join(dir, f), "utf8")))));
    const google = cases.filter((c) => c.tags?.some((t) => t === "gmail" || t === "meet"));
    expect(google.length).toBeGreaterThan(0);

    for (const golden of google) {
      const userEmail = golden.user.emails[0];
      for (const source of golden.sources) {
        const where = `${golden.id}/${source.id}`;
        const lines = source.text.split("\n");
        if (source.kind === "email") {
          // 제목 줄 + 빈 줄 + 본문. 보낸 사람 · 받는 사람은 본문이 아니라 participants로
          expect(lines[0], where).toMatch(/^제목: \S/);
          expect(lines[1], where).toBe("");
          expect(source.participants?.from, where).toBeDefined();
          expect(source.participants?.to?.length, where).toBeGreaterThan(0);
          // 사용자는 연결한 주소로 보낸 사람 · 받는 사람 · 참조에 있다. 회사 그룹 주소(사용자와 같은 도메인)로만 받은 메일은 예외
          const people = [source.participants?.from, ...(source.participants?.to ?? []), ...(source.participants?.cc ?? [])];
          const domain = userEmail.split("@")[1];
          const viaGroup = source.participants?.to?.every((p) => p.email?.endsWith(`@${domain}`) && p.email !== userEmail);
          if (!viaGroup) expect(people.map((p) => p?.email), where).toContain(userEmail);
        } else if (lines[0].startsWith("[Google Meet · ")) {
          // 머리줄 + "이름: 글", 같은 화자의 이어진 항목은 한 줄로
          expect(lines[0], where).toMatch(/^\[Google Meet · [^\]]+\]$/);
          const speakers = lines.slice(1).map((line) => line.match(/^([^:]+): \S/)?.[1]);
          expect(speakers, where).not.toContain(undefined);
          expect(speakers, where).toContain(golden.user.name);
          speakers.forEach((s, i) => expect(s === speakers[i - 1], `${where} 줄 ${i + 2}`).toBe(false));
          // 사용자는 참석자에 프로필 이름 + 연결한 주소로 한 번만
          const me = (source.participants?.attendees ?? []).filter((p) => p.email === userEmail || p.name === golden.user.name);
          expect(me, where).toEqual([{ name: golden.user.name, email: userEmail }]);
        } else {
          // Notion 회의록 (pageToItem): "# 제목" + 정리한 본문, 일정 참석자가 붙음
          expect(source.kind, where).toBe("meeting");
          expect(lines[0], where).toMatch(/^# \S/);
          expect(source.text, where).toContain("[AI 요약]");
          expect(source.participants?.attendees?.length, where).toBeGreaterThan(1);
        }
      }
    }
  });

  // Gmail 어댑터가 만들 원문과 같은 모양의 케이스(gmail · meet 태그)의 메일은 연결로 가져온 원문이다: eval도 운영과 같은 길(인용된 옛 메일 속 후보 버리기)을 탄다.
  // 태그 없는 옛 메일 케이스는 사용자가 직접 붙여 넣은 원문이라 표시가 없고, 그 규칙을 타지 않는다.
  it("Gmail · Meet 케이스의 메일은 연결로 가져온 원문으로 표시되고, 다른 종류의 원문에는 표시가 없다", async () => {
    const dir = path.resolve(import.meta.dirname, "../../../evals/golden");
    const files = (await readdir(dir)).filter((f) => f.endsWith(".json"));
    let marked = 0;
    for (const file of files) {
      const golden = goldenCaseSchema.parse(JSON.parse(await readFile(path.join(dir, file), "utf8")));
      const google = golden.tags?.some((t) => t === "gmail" || t === "meet") ?? false;
      for (const source of golden.sources) {
        const where = `${golden.id}/${source.id}`;
        if (source.kind === "email" && google) {
          expect(source.from_connector, where).toBe(true);
          marked++;
        } else if (source.kind !== "email") {
          expect(source.from_connector, where).toBeUndefined();
        }
      }
    }
    expect(marked).toBeGreaterThan(0);
  });

  // 기계 검증(verify.ts)은 연결로 가져온 메일에서 인용된 옛 메일에만 있는 구절을 버린다. 정답 Action의 근거 구절이 모두 그 안에 있으면 정답을 스스로 버리게 된다.
  // (근거 중 일부가 인용 속에 있는 것은 괜찮다: 채점은 근거 중 하나만 겹쳐도 짝지으므로 새로 쓴 글의 구절만 뽑아도 정답이다)
  it("정답 Action마다 근거 구절 하나 이상은 인용된 옛 메일 밖(새로 쓴 글)에 있다", async () => {
    const dir = path.resolve(import.meta.dirname, "../../../evals/golden");
    const files = (await readdir(dir)).filter((f) => f.endsWith(".json"));
    let checked = 0;
    for (const file of files) {
      const golden = goldenCaseSchema.parse(JSON.parse(await readFile(path.join(dir, file), "utf8")));
      const freshText = new Map(
        golden.sources.map((source) => {
          const at = source.kind === "email" && source.from_connector ? quotedHistoryStart(source.text) : null;
          return [source.id, at === null ? source.text : source.text.slice(0, at)] as const;
        }),
      );
      for (const action of golden.expected_actions) {
        const reachable = action.evidence.some((e) => quoteInText(e.quote, freshText.get(e.source) ?? ""));
        expect(reachable, `${golden.id}: ${action.title}`).toBe(true);
        checked++;
      }
    }
    expect(checked).toBeGreaterThan(0);
  });
});
