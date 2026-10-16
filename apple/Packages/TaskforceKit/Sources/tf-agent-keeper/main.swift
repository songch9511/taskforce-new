import Foundation
import TaskforceAgentWire

// 지킴이 helper (OA D3a 13장). 본체는 `KeeperMain`, 이 파일은 시험 · 개발용 SwiftPM 짝이다 (앱 번들은 `apple/Helpers/tf-agent-keeper` → `Taskforce Agent.app`)
// 부른 쪽 확인 (14장 12): 시험이 `TF_KEEPER_CALLER_REQUIREMENT`로 서명 요구사항을 주면 그것으로, 아니면 살아 있는 부모만 (Debug 빌드 전용, 앱 번들에 넣지 않는다)
#if DEBUG
let caller = ProcessInfo.processInfo.environment["TF_KEEPER_CALLER_REQUIREMENT"].map { KeeperCaller.Policy.requirement($0) } ?? .liveParent
#else
let caller = KeeperCaller.Policy.signedApp
#endif
KeeperMain.exitProcess(KeeperMain.main(arguments: Array(CommandLine.arguments.dropFirst()), caller: caller))
