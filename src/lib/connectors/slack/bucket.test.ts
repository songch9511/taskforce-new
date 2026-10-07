import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { bucketSlackMessages, compareSlackTs, renderSlackText, slackIdsToName, threadStartIds, type SlackBucketContext, type StoredSlackMessage } from "./bucket";

const ME = "U_ME";
const KIM = "U_KIM";
const PARK = "U_PARK";
const CHOI = "U_CHOI";

/** 한국 시간 "2026-10-07 14:30" + 초 → Slack ts */
const ts = (kst: string, seconds = 0) => `${Date.parse(`${kst.replace(" ", "T")}:00+09:00`) / 1000 + seconds}.000100`;

const msg = (over: Partial<StoredSlackMessage> & Pick<StoredSlackMessage, "ts" | "senderId" | "text">): StoredSlackMessage => ({
  channelId: "D1",
  channelType: "im",
  threadTs: null,
  editedAt: null,
  ...over,
});

const context = (over: Partial<SlackBucketContext> = {}): SlackBucketContext => ({
  now: new Date("2026-10-08T00:00:00+09:00"),
  me: { slackId: ME, name: "윤지호" },
  people: new Map([
    [KIM, "김대표"],
    [PARK, "박지훈"],
    [CHOI, "최유나"],
  ]),
  conversations: new Map([
    ["D1", "김대표"],
    ["C_OPS", "ops"],
    ["C_SALES", "sales"],
  ]),
  teamUrl: "https://acme.slack.com/",
  startedThreads: new Set(),
  ...over,
});

type GoldenSource = { id: string; text: string; participants: unknown };
const golden = (file: string, sourceId: string): GoldenSource => {
  const data = JSON.parse(readFileSync(join(process.cwd(), "evals/golden", `${file}.json`), "utf8")) as { sources?: GoldenSource[]; source?: GoldenSource };
  return (data.sources ?? [data.source!]).find((s) => s.id === sourceId)!;
};

describe("bucketSlackMessages — 골든셋과 같은 본문 (slack-integration.md 2-5)", () => {
  it("DM: 머리줄은 상대 이름, 본인 줄은 프로필 이름, 관련자는 상대와 이용자", () => {
    const [bucket] = bucketSlackMessages(
      [
        msg({ ts: ts("2026-10-07 14:30"), senderId: KIM, text: "제안서는 월요일에 받아도 괜찮아요. 투자 미팅이 화요일로 밀렸어요." }),
        msg({ ts: ts("2026-10-07 14:32"), senderId: ME, text: "넵 알겠습니다!" }),
      ],
      context(),
    );
    const expected = golden("seq-slack-friday-to-monday", "slack-1007");
    expect(bucket.item.text).toBe(expected.text);
    expect(bucket.item.participants).toEqual(expected.participants);
    expect(bucket.item).toMatchObject({
      kind: "message",
      title: "Slack · DM with 김대표",
      occurredAt: new Date("2026-10-07T14:30:00+09:00"),
      externalId: `c:D1:${ts("2026-10-07 14:30")}`,
      externalVersion: ts("2026-10-07 14:32"),
      externalUrl: `https://acme.slack.com/archives/D1/p${ts("2026-10-07 14:30").replace(".", "")}`,
      writtenByMe: null,
    });
  });

  it("내가 쓴 줄만 있는 DM도 상대는 대화 정보에서 (D7)", () => {
    const [bucket] = bucketSlackMessages(
      [
        msg({ ts: ts("2026-10-05 18:30"), senderId: ME, text: "대표님 말씀하신 IR 자료는 금요일까지 정리해서 공유드릴게요" }),
        msg({ ts: ts("2026-10-05 18:31"), senderId: ME, text: "혹시 추가로 필요한 거 있으시면 말씀 주세요" }),
      ],
      context(),
    );
    const expected = golden("slack-dm-only-me", "slack-1005");
    expect(bucket.item.text).toBe(expected.text);
    expect(bucket.item.participants).toEqual(expected.participants);
  });

  it("채널: 언급은 @이름, 관련자는 글을 쓴 사람 순서 + 이용자", () => {
    const parent = ts("2026-10-05 11:30");
    const [bucket] = bucketSlackMessages(
      [
        msg({ channelId: "C_OPS", channelType: "channel", ts: parent, senderId: PARK, text: `<@${ME}> 배포 체크리스트 한 번 검토 부탁드려요` }),
        msg({ channelId: "C_OPS", channelType: "channel", ts: ts("2026-10-05 11:33"), threadTs: parent, senderId: CHOI, text: "참고로 배포는 목요일 저녁이라 수요일까지 봐주시면 좋아요" }),
        msg({ channelId: "C_OPS", channelType: "channel", ts: ts("2026-10-05 11:40"), threadTs: parent, senderId: ME, text: "넵 수요일까지 보고 코멘트 남길게요" }),
      ],
      context(),
    );
    const expected = golden("slack-channel-mention-thread", "slack-1005");
    expect(bucket.item.text).toBe(expected.text);
    expect(bucket.item.participants).toEqual(expected.participants);
    expect(bucket.item.title).toBe("Slack · #ops");
    expect(bucket.item.externalId).toBe(`t:C_OPS:${parent}:${parent}`);
  });

  it("첫 글이 없는 스레드: 앞 원문에 없으면 '스레드 중간부터', 넣었으면 '스레드 이어서'", () => {
    const parent = ts("2026-10-07 16:00");
    const reply = msg({
      channelId: "C_SALES",
      channelType: "channel",
      ts: ts("2026-10-07 16:45"),
      threadTs: parent,
      senderId: CHOI,
      text: `<@${ME}> 이거 금요일까지 될까요? 고객사에서 다시 물어보네요`,
    });
    const [middle] = bucketSlackMessages([reply], context());
    const expected = golden("slack-channel-mid-thread", "slack-1007");
    expect(middle.item.text).toBe(expected.text);
    expect(middle.item.participants).toEqual(expected.participants);
    expect(middle.item.externalUrl).toBe(`https://acme.slack.com/archives/C_SALES/p${reply.ts.replace(".", "")}?thread_ts=${parent}&cid=C_SALES`);

    expect(threadStartIds([reply])).toEqual([`t:C_SALES:${parent}:${parent}`]);
    const [continued] = bucketSlackMessages([reply], context({ startedThreads: new Set([`t:C_SALES:${parent}:${parent}`]) }));
    expect(continued.item.text.split("\n")[0]).toBe("[#sales · 스레드 이어서]");
  });

  it("그룹 DM: 머리줄 [그룹 DM], 관련자는 글을 쓴 사람", () => {
    const [bucket] = bucketSlackMessages(
      [
        msg({ channelId: "G1", channelType: "mpim", ts: ts("2026-10-06 21:00"), senderId: PARK, text: "내일 데모 리허설 자료는 제가 오늘 밤까지 만들게요" }),
        msg({ channelId: "G1", channelType: "mpim", ts: ts("2026-10-06 21:01"), senderId: CHOI, text: "그럼 저는 고객 명단 정리해서 내일 오전에 공유할게요" }),
        msg({ channelId: "G1", channelType: "mpim", ts: ts("2026-10-06 21:02"), senderId: ME, text: "좋아요 두 분 감사합니다!" }),
      ],
      context(),
    );
    const expected = golden("slack-mpim-others-commit", "slack-1006");
    expect(bucket.item.text).toBe(expected.text);
    expect(bucket.item.participants).toEqual(expected.participants);
    expect(bucket.item.title).toBe("Slack · Group DM");
  });

  it("앱 메시지는 sender id를 이름 조회에 보내지 않고, DM에서도 Slack app 화자를 관련자로 보존한다", () => {
    const botMessage = msg({
      ts: ts("2026-10-06 21:00"),
      senderId: "bot:B123",
      text: "배포 일정은 금요일입니다.\n\n담당자는 <@U_KIM>이며 <@U_PARK>에게 넘겨요.",
    });
    const humanMessage = { ...botMessage, ts: ts("2026-10-06 21:01"), senderId: KIM, text: "네, 확인할게요." };
    const [bucket] = bucketSlackMessages([botMessage, humanMessage], context());

    expect(bucket.item.text).toBe(
      "[DM · Slack app]\nSlack app: 배포 일정은 금요일입니다.\nSlack app: 담당자는 @김대표이며 @박지훈에게 넘겨요.\n김대표: 네, 확인할게요.",
    );
    expect(bucket.item.participants).toEqual({ attendees: [{ name: "Slack app" }, { name: "김대표" }, { name: "박지훈" }, { name: "윤지호" }] });
    expect(slackIdsToName([botMessage, humanMessage], ME)).toEqual({ users: [KIM, PARK], conversations: [] });
  });
});

describe("bucketSlackMessages — 자르기 (D1)", () => {
  const dm = (kst: string, text = "메모", seconds = 0) => msg({ ts: ts(kst, seconds), senderId: KIM, text });

  it("30분 넘게 멈추면 다음 묶음. 앞 묶음은 바로 넣을 수 있고, 마지막 묶음은 30분이 지나야 넣는다", () => {
    const now = new Date("2026-10-06T11:40:00+09:00");
    const buckets = bucketSlackMessages([dm("2026-10-06 10:12"), dm("2026-10-06 10:13"), dm("2026-10-06 11:20")], context({ now }));
    expect(buckets.map((b) => b.messages.length)).toEqual([2, 1]);
    expect(buckets[0].item.lastEditedAt.getTime()).toBeLessThanOrEqual(now.getTime() - 30 * 60_000);
    expect(buckets[1].item.lastEditedAt).toEqual(new Date("2026-10-06T11:20:00+09:00"));
  });

  it("한국 시간 자정을 넘지 않고, 첫 글에서 3시간 · 100개가 넘으면 자른다. 잘린 앞 묶음도 바로 넣을 수 있다", () => {
    const now = new Date("2026-10-07T00:10:00+09:00");
    expect(bucketSlackMessages([dm("2026-10-06 23:50"), dm("2026-10-07 00:05")], context({ now })).map((b) => b.messages.length)).toEqual([1, 1]);

    // 20분마다 한 줄씩 4시간: 첫 글에서 3시간 안의 10줄 + 나머지 3줄
    const steady = Array.from({ length: 13 }, (_, i) => dm("2026-10-06 09:00", "메모", i * 20 * 60));
    const cut = bucketSlackMessages(steady, context({ now: new Date("2026-10-06T13:05:00+09:00") }));
    expect(cut.map((b) => b.messages.length)).toEqual([10, 3]);
    expect(cut[0].item.lastEditedAt.getTime()).toBeLessThanOrEqual(new Date("2026-10-06T12:35:00+09:00").getTime());

    const burst = Array.from({ length: 150 }, (_, i) => dm("2026-10-06 09:00", "메모", i));
    expect(bucketSlackMessages(burst, context()).map((b) => b.messages.length)).toEqual([100, 50]);
  });

  it("대화 · 스레드마다 따로 묶고, 순서가 뒤바뀌어 와도 ts 순으로 읽는다", () => {
    const parent = ts("2026-10-06 09:00");
    const buckets = bucketSlackMessages(
      [
        dm("2026-10-06 09:05", "두 번째"),
        dm("2026-10-06 09:01", "첫 번째"),
        msg({ channelId: "D1", ts: ts("2026-10-06 09:02"), threadTs: parent, senderId: KIM, text: "스레드 답글" }),
      ],
      context(),
    );
    expect(buckets.map((b) => b.item.externalId)).toEqual([`c:D1:${ts("2026-10-06 09:01")}`, `t:D1:${parent}:${ts("2026-10-06 09:02")}`]);
    expect(buckets[0].item.text).toBe("[DM · 김대표]\n김대표: 첫 번째\n김대표: 두 번째");
    // DM은 모든 글을 남기므로 스레드의 첫 글은 본 대화 원문에 있다
    expect(buckets[1].item.text.split("\n")[0]).toBe("[DM · 김대표 · 스레드 이어서]");
  });

  it("고친 글은 고친 시각까지 기다린다. 글이 없는 메시지(파일만)는 줄로 쓰지 않고, 다 비면 원문도 비운다", () => {
    const [edited] = bucketSlackMessages([{ ...dm("2026-10-06 09:00"), editedAt: new Date("2026-10-06T09:50:00+09:00") }], context());
    expect(edited.item.lastEditedAt).toEqual(new Date("2026-10-06T09:50:00+09:00"));
    const [empty] = bucketSlackMessages([dm("2026-10-06 09:00", "  ")], context());
    expect(empty.item.text).toBe("");
    expect(empty.messages).toHaveLength(1);
  });
});

describe("renderSlackText", () => {
  const ctx = context();
  it("언급 · 채널 · 링크 · 특수 언급 · HTML 이스케이프를 읽는 글로", () => {
    expect(renderSlackText(`<@${ME}> <@${KIM}> <@U_NEW|old name> 보세요`, ctx)).toBe("@윤지호 @김대표 @old name 보세요");
    expect(renderSlackText("<#C_OPS> <#C_X|random> <!here> <!subteam^S1|@design>", ctx)).toBe("#ops #random @here @design");
    expect(renderSlackText("<https://a.co/x|기획서> <https://a.co/y> <mailto:a@b.co|a@b.co>", ctx)).toBe("기획서 (https://a.co/x) https://a.co/y a@b.co");
    expect(renderSlackText("A &lt; B &amp;&amp; C &gt; D :+1:", ctx)).toBe("A < B && C > D :+1:");
  });

  it("이름을 알아야 하는 id: 보낸 사람 · 언급(본인 제외), 그룹 DM이 아닌 대화", () => {
    const ids = slackIdsToName(
      [
        msg({ ts: "1.0", senderId: KIM, text: `<@${ME}> <@U_NEW>` }),
        msg({ channelId: "G1", channelType: "mpim", ts: "2.0", senderId: ME, text: "hi" }),
      ],
      ME,
    );
    expect(ids).toEqual({ users: [KIM, "U_NEW"], conversations: ["D1"] });
  });

  it("ts는 초 · 소수부를 따로 비교한다", () => {
    expect(["1727678400.000200", "1727678400.000100", "1727678399.999999"].sort(compareSlackTs)).toEqual([
      "1727678399.999999",
      "1727678400.000100",
      "1727678400.000200",
    ]);
  });
});
