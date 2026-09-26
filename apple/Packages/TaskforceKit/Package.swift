// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskforceKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TaskforceKit", targets: ["TaskforceKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.55.0"),
    ],
    targets: [
        .target(
            name: "TaskforceKit",
            dependencies: [.product(name: "Supabase", package: "supabase-swift")]
        ),
        .testTarget(name: "TaskforceKitTests", dependencies: ["TaskforceKit"]),
    ]
)
