import TaskforceAgentWire

// 지킴이 helper (OA D3a 13장). 본체는 `KeeperMain`, 이 파일은 시험 · 개발용 SwiftPM 짝이다 (앱 번들은 `apple/Helpers/tf-agent-keeper` → `Taskforce Agent.app`)
KeeperMain.exitProcess(KeeperMain.main(arguments: Array(CommandLine.arguments.dropFirst())))
