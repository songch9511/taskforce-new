import TaskforceAgentWire

// Claude Code PreToolUse · SessionStart 훅 (OA D3a 계약 2.3 · 2.6). 본체는 `HookMain`, 이 파일은 시험 · 개발용 SwiftPM 짝이다 (앱 번들은 `apple/Helpers/tf-agent-hook`)
HookMain.exitProcess(HookMain.main(arguments: Array(CommandLine.arguments.dropFirst())))
