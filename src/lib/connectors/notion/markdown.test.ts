import { describe, expect, it } from "vitest";

import { cleanNotionMarkdown } from "./markdown";

// 실제 Notion 회의록 페이지의 enhanced markdown 모양 (이름은 바꿈)
const page = `## 💬  Discussion {color="gray_bg"}
![](https://prod-files-secure.s3.us-west-2.amazonaws.com/a/b/image.png?X-Amz-Signature=abc)
<meeting-notes readOnlyViewMeetingNoteUrl="https://app.notion.com/p/x#y">
\tMeeting <mention-date start="2026-09-22"/>
\t<summary>
\t\t### 액션 아이템
\t\t- [ ] 태오: 호퍼·탱크 도면 역설계 결과물 분칠 — 수요일 저녁까지 [^https://app.notion.com/p/a#b] [^https://app.notion.com/p/a#c]
\t\t- [ ] 준서: FreeCAD MCP 벤치마크 [^https://app.notion.com/p/a#d]
\t\t<table fit-page-width="true" header-row="true">
<tr>
<td>담당자</td>
<td>작업 내용</td>
</tr>
<tr>
<td>태오</td>
<td>통합 도면 역설계 구현</td>
</tr>
\t\t</table>
\t</summary>
\t<notes>
\t\t<empty-block/>
\t</notes>
\t<transcript>
\t\tTranscript omitted. Use the view tool with the meeting note url (https://app.notion.com/p/x#y) to view this transcript.
\t</transcript>
</meeting-notes>
<empty-block/>
### 액션 설정
- <mention-user url="user://ea08642c"/>: annotation 기획 → spec 기반 생성
- <mention-user url="user://ffff"/>: QA
- 참고: <mention-page url="https://app.notion.com/p/z">SFT 스펙 문서</mention-page>
## ✔️  Action Item {color="gray_bg"}
<database url="https://app.notion.com/p/db" inline="true"></database>`;

describe("cleanNotionMarkdown", () => {
  const text = cleanNotionMarkdown(page, { ea08642c: "도윤" });

  it("근거 각주 · 이미지 · 인라인 DB · 색 지정을 걷어 낸다", () => {
    expect(text).not.toMatch(/\[\^|amazonaws|<database|color=/);
    expect(text).toContain("## 💬  Discussion");
  });

  it("사람 · 날짜 · 페이지 언급을 글자로 바꾼다", () => {
    expect(text).toContain("- @도윤: annotation 기획 → spec 기반 생성");
    expect(text).toContain("- @알 수 없는 사용자: QA");
    expect(text).toContain("Meeting 2026-09-22");
    expect(text).toContain("참고: SFT 스펙 문서");
  });

  it("회의록 블록은 소제목만 남기고, 생략된 전사 안내문은 버린다", () => {
    expect(text).toContain("[AI 요약]");
    expect(text).not.toMatch(/<\/?(meeting-notes|summary|notes|transcript)|Transcript omitted/);
  });

  it("액션 아이템 문장은 인용할 수 있게 그대로 남는다", () => {
    expect(text).toContain("- [ ] 태오: 호퍼·탱크 도면 역설계 결과물 분칠 — 수요일 저녁까지");
  });

  it("표는 행마다 칸을 | 로 잇는다", () => {
    expect(text).toContain("담당자 | 작업 내용\n태오 | 통합 도면 역설계 구현");
  });

  it("빈 블록과 긴 빈 줄을 줄인다", () => {
    expect(text).not.toMatch(/<empty-block|\n{3,}|\t/);
  });
});
