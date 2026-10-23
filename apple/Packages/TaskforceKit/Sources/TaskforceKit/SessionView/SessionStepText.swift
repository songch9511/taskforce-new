#if os(macOS)
import Foundation

/// 단계 줄의 글 (DZ v2 E2 · E3): "{도구 이름} · {파일 이름 | description}". 대상은 **파일 이름만**이다 (경로 · 명령 · 검색어는 줄에 없다)
public enum SessionStepText {
    /// 파일 이름이 이보다 길면 가운데를 줄이고 확장자를 지킨다
    public static let fileNameLimit = 30

    public static func line(name: String, target: String?) -> String {
        guard let target, !target.isEmpty else { return name }
        return "\(name) · \(target)"
    }

    /// 접힌 묶음의 줄: 도구 이름을 처음 쓴 순서로 한 번씩 " · "로 (개수는 화면에 없다)
    public static func groupLabel(names: [String]) -> String {
        var seen = Set<String>()
        var ordered: [String] = []
        for name in names where seen.insert(name).inserted { ordered.append(name) }
        return ordered.joined(separator: " · ")
    }

    /// 긴 파일 이름은 가운데를 "…"로 줄이고 확장자를 지킨다 (30자 안). 확장자가 너무 길면 확장자 없이 줄인다
    public static func shortFileName(_ name: String) -> String {
        guard name.count > fileNameLimit else { return name }
        var ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let tail = String(name[dot...])
            if tail.count <= 9 { ext = tail }
        }
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count))
        let budget = fileNameLimit - ext.count - 1
        let tailCount = max(1, budget / 3)
        let headCount = budget - tailCount
        return String(base.prefix(headCount)) + "…" + String(base.suffix(tailCount)) + ext
    }

    /// 경로의 마지막 성분 (파일 이름). 끝이 `/`이거나 비면 nil. 제목과 같은 규칙으로 정리한다 (공백류는 한 칸, 제어 · 서식 글자는 지운다)
    public static func fileName(fromPath path: String) -> String? {
        guard !path.isEmpty, !path.hasSuffix("/"), let last = path.split(separator: "/", omittingEmptySubsequences: true).last else { return nil }
        return ExternalSessionRules.sanitizedTitle(String(last))
    }
}
#endif
