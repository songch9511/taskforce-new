// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskforceKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TaskforceKit", targets: ["TaskforceKit"]),
        .library(name: "TaskforceUI", targets: ["TaskforceUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.55.3"),
    ],
    targets: [
        // 화면 없는 공유 코드: 서버 API · Supabase 읽기 · 순수 규칙 (테스트로 고정)
        .target(
            name: "TaskforceKit",
            dependencies: [.product(name: "Supabase", package: "supabase-swift")]
        ),
        // Figma 디자인 시스템 v1의 토큰(색 · 간격 · 글자)과 부품. iOS · macOS 공용.
        .target(
            name: "TaskforceUI",
            dependencies: ["TaskforceKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "TaskforceKitTests", dependencies: ["TaskforceKit"]),
        // 토큰 이름 · Light/Dark 값(Figma 변수) · 글자 대비, 부품의 순수 규칙
        .testTarget(name: "TaskforceUITests", dependencies: ["TaskforceUI"]),
    ]
)
