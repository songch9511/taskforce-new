import TaskforceAgentWire

// 앱 번들 `Contents/Helpers/tf-agent-mcp`: Taskforce MCP 서버 `tf`, 도구 `ask_user` (OA D3a 계약 3.3). 본체는 Kit `TaskforceAgentWire.MCPMain`
HookMain.exitProcess(MCPMain.main(arguments: Array(CommandLine.arguments.dropFirst())))
