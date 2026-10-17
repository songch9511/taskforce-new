// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskforceKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TaskforceKit", targets: ["TaskforceKit"]),
        .library(name: "TaskforceUI", targets: ["TaskforceUI"]),
        // 앱 번들 helper 셋(`Contents/Helpers/tf-agent-hook` · `tf-agent-mcp` · `Taskforce Agent.app` 지킴이)의 본체 (OA D3a). Xcode helper 타깃이 이것만 링크한다 (Supabase · TaskforceKit 0)
        .library(name: "TaskforceAgentWire", targets: ["TaskforceAgentWire"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.55.3"),
    ],
    targets: [
        // Claude Code 훅 · MCP helper와 bridge 소켓의 선 규약 (OA D3a). 의존 0 (Foundation · Darwin만)
        .target(name: "TaskforceAgentWire"),
        // 화면 없는 공유 코드: 서버 API · Supabase 읽기 · 순수 규칙 (테스트로 고정)
        .target(
            name: "TaskforceKit",
            dependencies: ["TaskforceAgentWire", .product(name: "Supabase", package: "supabase-swift")]
        ),
        // Figma 디자인 시스템 v1의 토큰(색 · 간격 · 글자)과 부품. iOS · macOS 공용.
        .target(
            name: "TaskforceUI",
            dependencies: ["TaskforceKit"],
            resources: [.process("Resources")]
        ),
        // 시험 · 개발용 실행 파일 (앱은 링크하지 않는다): helper 셋의 SwiftPM 짝과 가짜 `claude` (OA D3a 계약 2.1 · 4.3 · 13장)
        .executableTarget(name: "tf-agent-hook", dependencies: ["TaskforceAgentWire"]),
        .executableTarget(name: "tf-agent-mcp", dependencies: ["TaskforceAgentWire"]),
        .executableTarget(name: "tf-agent-keeper", dependencies: ["TaskforceAgentWire"]),
        .executableTarget(name: "FakeClaudeCode"),
        // bridge 계약 JSON(Fixtures/bridge-v1)은 서버 쪽 src/lib/bridge/swift-fixtures.test.ts도 같은 파일을 읽는다 (OA D2b).
        // Claude Code stream-json(Fixtures/claude-code-2.1.241)은 S0 실측에서 옮긴 사건 줄이다 (OA D3a 4.2). 실행 파일 셋은 시험이 빌드 폴더에서 찾아 띄운다
        .testTarget(
            name: "TaskforceKitTests",
            dependencies: ["TaskforceKit", "TaskforceAgentWire", "tf-agent-hook", "tf-agent-mcp", "tf-agent-keeper", "FakeClaudeCode"],
            resources: [.copy("Fixtures/bridge-v1"), .copy("Fixtures/claude-code-2.1.241")]
        ),
        .testTarget(name: "TaskforceAgentWireTests", dependencies: ["TaskforceAgentWire", "tf-agent-hook", "tf-agent-mcp"]),
        // 지킴이 helper를 실제 실행 파일로 띄워 본다 (가짜 `claude` = `/bin/sh`, OA D3a 13장)
        .testTarget(name: "TaskforceAgentKeeperTests", dependencies: ["TaskforceAgentWire", "tf-agent-keeper"]),
        // 토큰 이름 · Light/Dark 값(Figma 변수) · 글자 대비, 부품의 순수 규칙
        .testTarget(name: "TaskforceUITests", dependencies: ["TaskforceUI"]),
    ]
)
