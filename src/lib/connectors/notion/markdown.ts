// Notion "enhanced markdown"(GET /v1/pages/{id}/markdown)을 추출기에 넣을 평문으로 정리한다.
// 근거 인용은 이 정리된 텍스트에서 찾으므로, 사람이 읽는 내용은 그대로 두고 링크 · 태그 같은 잡음만 걷어 낸다.

export type UserNames = Record<string, string>;

export function cleanNotionMarkdown(markdown: string, users: UserNames = {}): string {
  let text = markdown;

  // AI 요약의 근거 각주 [^https://...], 이미지, 인라인 데이터베이스
  text = text.replace(/\s*\[\^[^\]]+\]/g, "");
  text = text.replace(/!\[[^\]]*\]\([^)]*\)/g, "");
  text = text.replace(/<database\b[^>]*>(?:<\/database>)?/g, "");

  // 사람 · 날짜 · 페이지 언급 → 글자
  text = text.replace(/<mention-user\b[^>]*url="user:\/\/([^"]+)"[^>]*?(?:\/>|>(.*?)<\/mention-user>)/g, (_m, id: string, inner?: string) =>
    `@${users[id] ?? (inner?.trim() || "알 수 없는 사용자")}`,
  );
  text = text.replace(/<mention-date\b[^>]*start="([^"]+)"[^>]*?(?:\/>|>.*?<\/mention-date>)/g, "$1");
  text = text.replace(/<mention-(?:page|database|link)\b[^>]*>(.*?)<\/mention-(?:page|database|link)>/g, "$1");
  text = text.replace(/<mention-[a-z]+\b[^>]*\/>/g, "");

  // 회의록 블록: 요약 · 메모 · 전사를 소제목으로
  text = text.replace(/^[ \t]*Transcript omitted\..*$/gm, "");
  text = text.replace(/<meeting-notes\b[^>]*>/g, "").replace(/<\/meeting-notes>/g, "");
  text = text.replace(/<summary>/g, "\n[AI 요약]").replace(/<notes>/g, "\n[메모]").replace(/<transcript>/g, "\n[녹음 전사]");
  text = text.replace(/<\/(?:summary|notes|transcript)>/g, "");

  // 표: 행마다 "칸 | 칸"
  text = text.replace(/<table\b[^>]*>([\s\S]*?)<\/table>/g, (_m, body: string) =>
    [...body.matchAll(/<tr>([\s\S]*?)<\/tr>/g)]
      .map((row) => [...row[1].matchAll(/<td>([\s\S]*?)<\/td>/g)].map((cell) => cell[1].trim()).join(" | "))
      .join("\n"),
  );

  // 빈 블록 · 색 지정 · 남은 태그
  text = text.replace(/<empty-block\s*\/>/g, "");
  text = text.replace(/\s*\{color="[^"]*"\}/g, "");
  text = text.replace(/<\/?(?:details|summary|callout|columns?|toggle)\b[^>]*>/g, "");

  // 들여쓰기 탭 → 공백 두 칸, 줄 끝 공백, 3줄 이상 빈 줄
  text = text.replace(/\t/g, "  ").replace(/[ \t]+$/gm, "").replace(/\n{3,}/g, "\n\n");
  return text.trim();
}
