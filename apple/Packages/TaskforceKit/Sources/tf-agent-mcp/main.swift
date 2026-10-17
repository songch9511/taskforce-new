import TaskforceAgentWire

// Taskforce MCP 서버 `tf` (도구 `ask_user`, OA D3a 계약 3.3). 본체는 `MCPMain`, 이 파일은 시험 · 개발용 SwiftPM 짝이다 (앱 번들은 `apple/Helpers/tf-agent-mcp`)
HookMain.exitProcess(MCPMain.main(arguments: Array(CommandLine.arguments.dropFirst())))
