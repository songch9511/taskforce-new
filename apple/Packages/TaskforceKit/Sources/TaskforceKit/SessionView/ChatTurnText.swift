import Foundation

extension ChatTurn {
    /// 화면이 보이는 에이전트 글 (복사하는 글도 같다): 펼쳤으면 전문, 잘렸으면 말줄임표로 끝난 글 (이미 "…"로 끝나면 더하지 않는다)
    public var visibleText: String {
        if let fullText { return fullText }
        guard isTruncated, !text.hasSuffix("…") else { return text }
        return text + "…"
    }
}
