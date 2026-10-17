import TaskforceAgentWire

// 앱 번들 `Contents/Helpers/Taskforce Agent.app`: `claude`의 지킴이 (OA D3a 13장). 화면 · Dock 없음. 본체는 Kit `TaskforceAgentWire.KeeperMain`
// 부른 쪽 확인 (14장 12): Release는 같은 팀 + 앱 identifier 서명 요구사항, Debug · 시험 호스트는 그 빌드의 앱 번들 id(격리 접두어 포함)와 위치
#if DEBUG
let caller = KeeperCaller.Policy.debugApp
#else
let caller = KeeperCaller.Policy.signedApp
#endif
KeeperMain.exitProcess(KeeperMain.main(arguments: Array(CommandLine.arguments.dropFirst()), caller: caller))
