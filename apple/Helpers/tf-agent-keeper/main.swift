import TaskforceAgentWire

// 앱 번들 `Contents/Helpers/Taskforce Agent.app`: `claude`의 지킴이 (OA D3a 13장). 화면 · Dock 없음. 본체는 Kit `TaskforceAgentWire.KeeperMain`
KeeperMain.exitProcess(KeeperMain.main(arguments: Array(CommandLine.arguments.dropFirst())))
