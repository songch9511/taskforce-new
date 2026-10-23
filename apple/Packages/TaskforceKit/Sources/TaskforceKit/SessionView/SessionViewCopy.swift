#if os(macOS)
import Foundation

/// 세션 보기 V1의 승인된 문구 (DZ oa-session-view-dz v2 "최종 문구 표", 사용자 승인 2026-10-22). 화면은 이 상수만 쓴다.
/// 시간 값 · 도구 이름 · 파일 이름 · description · 끝낸 코드의 n은 데이터라 문구가 아니다
public enum SessionViewCopy {
    // 일한 시간 · 복사 · 단계
    public static let workedFor = "Worked for"
    public static let working = "Working"
    public static let copy = "Copy"
    public static let copied = "Copied"
    public static let input = "Input"
    public static let result = "Result"
    public static let failed = "Failed"
    /// 접힌 묶음의 접근성 이름 (화면에는 개수가 없다)
    public static func steps(_ count: Int) -> String { "\(count) steps" }
    /// 묶음 머리 · 띠 · 옆줄의 접근성 값 (DZ v2: 묶음 · 줄 단추는 `aria-expanded` 상태를 가진다). 화면에는 보이지 않는다.
    /// macOS의 SwiftUI에는 펼침 · 접힘을 말하는 접근성 상태(속성)가 없어(`DisclosureGroup` · `Section`의 `isExpanded` 바인딩뿐) VoiceOver가 쓰는 표준 낱말 둘을 값으로 쓴다
    /// (코디네이터 승인: 플랫폼 문구. 문구 표는 `docs/agent-gateway.md` 21-5의 접근성 표)
    public static let expanded = "Expanded"
    public static let collapsed = "Collapsed"

    // 승인된 재사용
    public static let showAll = "Show all"
    public static let showLess = "Show less"
    public static let showEarlier = "Show earlier"
    public static let back = "Back"
    public static let tryAgain = "Try again"
    public static let running = "Running"
    public static let done = "Done"

    // 백그라운드 도구
    public static let backgroundTasks = "Background tasks"
    /// 옆줄 머리의 접는 단추의 접근성 이름
    public static let hideBackgroundTasks = "Hide Background tasks"
    public static let command = "Command"
    public static let agent = "Agent"
    public static let task = "Task"
    public static let output = "Output"
    public static let stopped = "Stopped"
    public static let noOutputYet = "No output yet"
    public static let couldNotLoadOutput = "Couldn't load this output"
    public static func exitCode(_ code: Int) -> String { "Exit code \(code)" }
}
#endif
