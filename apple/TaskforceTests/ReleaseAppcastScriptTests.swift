import Foundation
import Testing

/// 배포 스크립트의 Sparkle appcast 단계 (OA M1b U5). `scripts/release-mac-dmg.sh`의 `make_appcast`만 떼어 가짜 도구 · 가짜 Keychain 조회로 돌린다.
/// 서명 · 공증 · DMG · 진짜 `generate_appcast` · 진짜 Keychain은 쓰지 않는다. 스크립트는 appcast를 로컬 폴더에만 만들고 올리지 않는다.
struct ReleaseAppcastScriptTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var scriptURL: URL { repo.appending(path: "scripts/release-mac-dmg.sh") }

    static func scriptText() throws -> String {
        try String(contentsOf: scriptURL, encoding: .utf8)
    }

    static func bash(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    // MARK: 함수만 떼어 돌리기

    struct AppcastRun {
        var status: Int32
        var stdout: String
        var stderr: String
        /// 가짜 도구가 받은 인자 (도구가 돌지 않았으면 nil)
        var toolArguments: [String]?
        var directory: URL
        var appcastFolder: URL
    }

    /// - keychainHasKey: 가짜 `security`가 항목을 찾았는지 (진짜 Keychain은 조회하지 않는다)
    static func runMakeAppcast(
        feed: String = "https://updates.example.com/taskforce/appcast.xml",
        publicKey: String = "PUBLIC-KEY-PLACEHOLDER",
        prefix: String = "https://updates.example.com/taskforce/",
        keychainHasKey: Bool = true,
        toolExists: Bool = true,
        toolStatus: Int = 0
    ) throws -> AppcastRun {
        let lines = try scriptText().components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("make_appcast() {") }),
              let end = lines[start...].firstIndex(of: "}") else { throw CocoaError(.fileReadCorruptFile) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "ReleaseAppcastScriptTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let function = directory.appending(path: "function.sh")
        let dmg = directory.appending(path: "Taskforce-0.2.0-9.dmg")
        let tool = directory.appending(path: "generate_appcast")
        let appcastFolder = directory.appending(path: "appcast", directoryHint: .isDirectory)
        try lines[start ... end].joined(separator: "\n").write(to: function, atomically: true, encoding: .utf8)
        try Data("not really a dmg".utf8).write(to: dmg)
        if toolExists {
            let body = """
            #!/bin/bash
            printf '%s\\n' "$@" > "\(directory.path)/args.txt"
            while [[ $# -gt 0 ]]; do
              if [[ "$1" == "-o" ]]; then echo '<rss/>' > "$2"; fi
              shift
            done
            exit \(toolStatus)
            """
            try body.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }

        let securityStatus = keychainHasKey ? 0 : 44
        let result = try bash([
            "-c",
            "set -euo pipefail; fail() { printf '%s\\n' \"$*\" >&2; exit 1; }; security() { return \(securityStatus); }; source \"$1\"; shift; make_appcast \"$@\"",
            "bash", function.path,
            dmg.path, appcastFolder.path, feed, publicKey, prefix, tool.path, directory.appending(path: "appcast.log").path,
        ])
        let args = try? String(contentsOf: directory.appending(path: "args.txt"), encoding: .utf8)
        return AppcastRun(
            status: result.status, stdout: result.stdout, stderr: result.stderr,
            toolArguments: args.map { $0.components(separatedBy: "\n").dropLast().map { String($0) } },
            directory: directory, appcastFolder: appcastFolder
        )
    }

    static func cleanup(_ run: AppcastRun) {
        try? FileManager.default.removeItem(at: run.directory)
    }

    // MARK: 시험

    @Test func theScriptIsValidBash() throws {
        let result = try Self.bash(["-n", Self.scriptURL.path])
        #expect(result.status == 0, "\(result.stderr)")
    }

    @Test func helpMentionsTheAppcastOptions() throws {
        let result = try Self.bash([Self.scriptURL.path, "--help"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("--appcast-dir") && result.stdout.contains("--download-url-prefix"))
    }

    /// 피드 · 공개 키 · 도구 · Keychain 키 중 하나라도 없으면 건너뛰고 실패하지 않는다. 도구는 돌지 않고 appcast도 없다
    @Test func appcastIsSkippedWhenAnythingItNeedsIsMissing() throws {
        let cases: [(String, AppcastRun)] = [
            ("SUFeedURL", try Self.runMakeAppcast(feed: "")),
            ("SUPublicEDKey", try Self.runMakeAppcast(publicKey: "")),
            ("generate_appcast", try Self.runMakeAppcast(toolExists: false)),
            ("Keychain", try Self.runMakeAppcast(keychainHasKey: false)),
        ]
        for (missing, run) in cases {
            defer { Self.cleanup(run) }
            #expect(run.status == 0, "\(missing): \(run.stderr)")
            #expect(run.stdout.contains("건너뜀") && run.stdout.contains(missing), "\(missing): \(run.stdout)")
            #expect(run.toolArguments == nil, "\(missing): 도구가 돌면 안 된다")
            #expect(!FileManager.default.fileExists(atPath: run.appcastFolder.appending(path: "appcast.xml").path), "\(missing)")
            #expect(run.stderr.isEmpty, "\(missing)")
        }
    }

    /// 모두 있으면 DMG를 로컬 폴더에 복사하고 도구를 정해진 인자로만 부른다 (개인 키 인자 없음). 업로드는 하지 않는다
    @Test func appcastIsBuiltIntoALocalFolderOnly() throws {
        let run = try Self.runMakeAppcast()
        defer { Self.cleanup(run) }
        #expect(run.status == 0, "\(run.stderr)")
        let folder = run.appcastFolder.path
        #expect(run.toolArguments == ["--download-url-prefix", "https://updates.example.com/taskforce/", "-o", "\(folder)/appcast.xml", folder])
        #expect(FileManager.default.fileExists(atPath: run.appcastFolder.appending(path: "Taskforce-0.2.0-9.dmg").path))
        #expect(FileManager.default.fileExists(atPath: run.appcastFolder.appending(path: "appcast.xml").path))
        #expect(run.stdout.contains("업로드하지 않음"))
        #expect(run.stderr.isEmpty)
    }

    /// 도구는 접두어에 파일 이름을 상대 주소로 이어 붙인다: 끝의 "/"가 없으면 마지막 폴더가 사라진다 (`https://h/a` + 파일 → `https://h/파일`). 없으면 붙인다
    @Test func theDownloadPrefixAlwaysEndsWithASlash() throws {
        for given in ["https://updates.example.com/taskforce", "https://updates.example.com/taskforce/"] {
            let run = try Self.runMakeAppcast(prefix: given)
            defer { Self.cleanup(run) }
            #expect(run.status == 0, "\(run.stderr)")
            #expect(run.toolArguments?.dropFirst().first == "https://updates.example.com/taskforce/", "\(given)")
        }
    }

    @Test func aFailingToolStopsTheScriptWithTheLogPath() throws {
        let run = try Self.runMakeAppcast(toolStatus: 1)
        defer { Self.cleanup(run) }
        #expect(run.status == 1)
        #expect(run.stderr.contains("appcast") && run.stderr.contains("appcast.log"))
    }

    /// 공증 뒤, 공증하지 않은 DMG(`--skip-notarize`)에는 만들지 않는다
    @Test func theStepRunsAfterNotarizationAndNeverForAnUnnotarizedDmg() throws {
        let lines = try Self.scriptText().components(separatedBy: "\n")
        let call = try #require(lines.firstIndex { $0.hasPrefix("  make_appcast ") })
        let notarizedDmg = try #require(lines.firstIndex { $0.contains("notarize \"$DMG\" dmg") })
        let gatekeeper = try #require(lines.firstIndex { $0.contains("spctl -a -t open") && !$0.contains("|| true") })
        #expect(call > notarizedDmg && call > gatekeeper)
        // 호출은 `if (( SKIP_NOTARIZE ))` … `else` 가지 안에 있다
        let before = lines[..<call].reversed().first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("else") || $0.hasPrefix("if ") || $0.hasPrefix("step ") }
        #expect(before?.trimmingCharacters(in: .whitespaces) == "else")
        let guardLine = try #require(lines[..<call].reversed().first { $0.hasPrefix("if ") })
        #expect(guardLine.contains("SKIP_NOTARIZE"))
    }

    // MARK: 개인 키 · 게시 금지

    /// 주석이 아닌 줄에서 금지된 명령을 찾는다. 허용 목록 방식: `security`는 find-identity · cms · (-s -a만 쓴) find-generic-password만,
    /// 도구(`$tool`)는 `--download-url-prefix` · `-o`만. 키 생성 · 내보내기 · 인자로 키 넘기기 · 올리기 명령은 어디에도 없다.
    static func violations(in script: String) -> [String] {
        let separators = CharacterSet(charactersIn: " \t;|&()<>\"'`{}")
        let publishers: Set<String> = ["curl", "wget", "scp", "sftp", "rsync", "ssh", "aws", "gsutil", "gh", "rclone", "netlify", "vercel", "wrangler", "ftp", "az"]
        var found: [String] = []
        for (index, raw) in script.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let tokens = line.components(separatedBy: separators).filter { !$0.isEmpty }
            func flag(_ why: String) { found.append("\(index + 1): \(why)") }
            if line.contains("generate_keys") { flag("generate_keys") }
            if tokens.contains(where: { $0.hasPrefix("--ed-key-file") }) { flag("--ed-key-file") }
            for word in publishers where tokens.contains(word) { flag("게시 명령 \(word)") }
            if let git = tokens.firstIndex(of: "git"), tokens.dropFirst(git + 1).first == "push" { flag("git push") }
            if let security = tokens.firstIndex(of: "security") {
                let rest = Array(tokens.dropFirst(security + 1))
                switch rest.first {
                case "find-identity", "cms": break
                case "find-generic-password":
                    for token in rest.dropFirst() where token.hasPrefix("-") && !["-s", "-a"].contains(token) { flag("security find-generic-password \(token)") }
                default: flag("security \(rest.first ?? "")")
                }
            }
            if let tool = tokens.firstIndex(of: "$tool") {
                for token in tokens.dropFirst(tool + 1) where token.hasPrefix("-") && !["--download-url-prefix", "-o"].contains(token) { flag("도구 인자 \(token)") }
            }
        }
        return found
    }

    @Test func theScriptNeverReadsThePrivateKeyOrPublishes() throws {
        #expect(Self.violations(in: try Self.scriptText()) == [])
    }

    @Test func theScannerCatchesEachForbiddenWay() {
        for line in [
            "\"$tool\" -s \"$SECRET\" \"$dir\"",
            "\"$tool\" --ed-key-file key.txt \"$dir\"",
            "\"$tool\" --ed-key-file=key.txt \"$dir\"",
            "./bin/generate_keys -x out.txt",
            "security find-generic-password -s x -w",
            "security find-generic-password -s x -g",
            "security export -t identities",
            "security dump-keychain -d",
            "curl -T x.dmg https://host/",
            "gh release upload v1 x.dmg",
            "rsync -a dir host:/path",
            "aws s3 cp x.dmg s3://bucket/",
            "git push origin main",
            "  scp x.dmg host:",
        ] {
            #expect(!Self.violations(in: line).isEmpty, "잡아야 한다: \(line)")
        }
        for line in [
            "security find-identity -v -p codesigning",
            "security cms -D -i \"$PROFILE_FILE\"",
            "security find-generic-password -s \"https://sparkle-project.org\" -a \"ed25519\" >/dev/null 2>&1",
            "\"$tool\" --download-url-prefix \"$prefix\" -o \"$dir/appcast.xml\" \"$dir\" >\"$log\" 2>&1",
            "# curl는 쓰지 않는다 (generate_keys도)",
            "",
        ] {
            #expect(Self.violations(in: line).isEmpty, "통과해야 한다: \(line)")
        }
    }
}
