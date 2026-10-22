#if os(macOS)
import Darwin
import Foundation

/// Taskforce 창이 보여 줄 데스크톱 세션의 대화 읽기 (PR-D1 Kit, 계약 21.4 · DR-7 · DR-13 · DR-14 · 21.5 DT2 · DT8).
/// ES-01의 "머리 · 꼬리 메타데이터만"은 목록 · 레일의 약속이고, **대화 보기만 이 예외를 갖는다.** 그래서 범위를 좁게 닫는다.
///
/// 읽는 것
/// - **사용자가 연 그 세션 하나**의 `projects/<디렉터리>/<소문자 UUID>.jsonl`만. 다른 기록 · 등록 파일 · 자격 파일은 열지도 나열하지도 않는다 (폴더를 모를 때만 `projects`를 한 번 나열한다)
/// - 해석하는 줄은 셋뿐이다: `user`(텍스트 블록), `assistant`(텍스트 블록 · `tool_use`의 이름과 `description`만), `attachment.type == queued_command`이면서 `origin.kind == "peer"`(DR-7).
///   그 밖 모든 종류 — `attachment`의 다른 종류(`session_context`의 계정 이메일 · `credential_org` · `prompt_snapshot`), `api-request*`(시스템 프롬프트), 시스템 · 계정 줄 — 은 **대화로 만들지 않는다**:
///   `"user"` · `"assistant"` · `"queued_command"` 글자가 하나도 없는 줄은 디코딩조차 하지 않고, 글자가 있는 줄은(계정 · 첨부 줄에 우연히 있을 수도 있다) 디코딩하되 **선언한 칸만** 꺼낸다
///   (`thinking` · 도구 입력 · 도구 결과 · 첨부 칸은 선언하지 않아 값으로 남지 않는다. 디코딩은 그 줄을 잠깐 메모리에 둔다)
/// - 건너뛰는 줄: 서브에이전트(`isSidechain`) · 다른 세션 id를 단 줄 · 메타(`isMeta`, peer가 아니면) · `origin`이 있는데 peer가 아닌 줄(훅 · 작업 알림 등) · peer가 아닌 `queued_command` ·
///   Claude Code 표시 줄(`<command-name>` 등으로 시작하는 `user` 글 · `isCompactSummary` · `isVisibleInTranscriptOnly`)
/// - peer 줄의 글은 받는 쪽이 감싼 글(`message.content`, "not typed by your user …")이 아니라 보낸 글 `origin.body`다. 같은 (`msg_id`, 검증된 보낸 pid, 플러그인)은 한 번만 (`user`와 `queued_command` 두 모양으로 기록돼도). `msg_id`만 같은 다른 보낸이의 메시지는 가리지 않는다
///
/// 상한: 한 줄 1 MiB(넘으면 그 줄을 통째로 건너뛴다) · 한 번에 읽는 창 2 MiB · 처음 열면 꼬리부터 마지막 200개 · 이전 쪽은 **거슬러 간 거리**가 총량 16 MiB를 넘지 않게 · 글 한 칸 32 KiB.
/// 도구 줄은 이름과 `description`뿐이다. 입력 · 결과 본문은 펼칠 때(`detail`) 그 줄을 다시 읽어서 16 KiB까지만 준다 (결과는 그 줄 뒤로 총량 16 MiB 안에서 찾는다: 그보다 먼 결과는 못 찾는다).
/// 메모리에만 둔다 (디스크 캐시 0). 글 · 경로 · id를 로그에 남기지 않는다: `claude_app_transcript {result}` 코드 하나뿐.
/// 안전: 5.1과 같다 — `O_NOFOLLOW` · 이 uid · 일반 파일 (`ExternalSessionFileSystem.read`), 프로젝트 디렉터리 · 기록 파일 모두 기호 링크 아님.
/// 기록 글은 평문으로만 다룬다 (DT8): 링크 · 태그를 해석하지 않고, 제어 글자 · 눈에 보이지 않는 서식 글자(방향 바꿈 · 폭 없는 공백 · 태그 · 줄 구분 등)를 지운다 (ZWJ · ZWNJ는 둔다).
/// **빈 쪽(`turns`가 비었다)에 `hasEarlier`가 true여도 끝이 아니다**: 한 번에 읽는 창이 건너뛴 줄뿐일 수 있다. 끝은 `hasEarlier == false`다.
public struct ClaudeAppTranscriptReader: Sendable {
    public struct Limits: Equatable, Sendable {
        /// 한 번에 읽는 창 (처음 열 때의 꼬리 · 이전 쪽 · 이어 읽기 · 펼친 도구의 결과 찾기)
        public var windowBytes: Int
        public var maxLineBytes: Int
        /// 처음 열기 + 이전 쪽으로 읽는 총량 (이어 읽기는 세지 않는다)
        public var maxTotalBytes: Int
        public var pageTurns: Int
        public var maxTextBytes: Int
        public var maxDetailBytes: Int

        public static let standard = Limits()

        public init(windowBytes: Int = 2 << 20, maxLineBytes: Int = 1 << 20, maxTotalBytes: Int = 16 << 20, pageTurns: Int = 200, maxTextBytes: Int = 32 << 10, maxDetailBytes: Int = 16 << 10) {
            self.windowBytes = windowBytes
            self.maxLineBytes = maxLineBytes
            self.maxTotalBytes = maxTotalBytes
            self.pageTurns = pageTurns
            self.maxTextBytes = maxTextBytes
            self.maxDetailBytes = maxDetailBytes
        }
    }

    let fileSystem: ExternalSessionFileSystem
    /// `$HOME/.claude`
    let claudeDirectory: String
    let limits: Limits
    let log: any BridgeLogSink

    public init(fileSystem: ExternalSessionFileSystem = .live, claudeDirectory: String, limits: Limits = .standard, log: any BridgeLogSink = NoBridgeLog()) {
        self.fileSystem = fileSystem
        self.claudeDirectory = claudeDirectory
        self.limits = limits
        self.log = log
    }

    // MARK: 공개

    /// 그 세션의 기록을 찾아 꼬리부터 읽는다 (마지막 `pageTurns`개). 못 찾거나 열 수 없으면 `.unreadable`
    /// - cwd: 등록 파일의 작업 폴더. 있으면 프로젝트 디렉터리를 바로 짐작하고, 없거나 맞지 않으면 `projects` 아래 디렉터리 이름만 훑어 찾는다
    public func open(sessionID: String, cwd: String?) -> ClaudeAppTranscriptLoad {
        guard ExternalSessionRules.isCanonicalUUID(sessionID), let located = locate(sessionID: sessionID, cwd: cwd) else { return finish(.unreadable) }
        let size = max(0, located.entry.size)
        let length = Int(min(Int64(limits.windowBytes), size))
        let start = size - Int64(length)
        var data = Data()
        if length > 0 {
            guard let read = fileSystem.read(located.path, start, length) else { return finish(.unreadable) }
            data = read
        }
        var peers = PeerSeen()
        let scanned = scan(data, start: start, dropHead: start > 0, sessionID: sessionID, peers: &peers)
        var cursor = ClaudeAppTranscriptCursor(
            sessionID: sessionID, path: located.path, created: located.entry.created, earliestOffset: start, nextOffset: start + Int64(scanned.consumedEnd),
            coveredBytes: 0, discarding: false, peerIDs: peers.ids
        )
        if start > 0, !scanned.sawNewline {
            // 창 전체가 한 줄 안이다 (창보다 긴 줄): 그 줄은 건너뛰고, 끝나는 개행까지 이어 읽기에서도 버린다
            cursor.nextOffset = start + Int64(data.count)
            cursor.discarding = true
            cursor.coveredBytes = data.count
            return finish(.page(page(turns: [], cursor: cursor, skipped: 1)))
        }
        let (turns, earliest) = select(scanned)
        cursor.earliestOffset = earliest
        cursor.coveredBytes = Int(max(0, start + Int64(data.count) - earliest))
        return finish(.page(page(turns: turns, cursor: cursor, skipped: scanned.skipped)))
    }

    /// "Show earlier": 지금까지 읽은 가장 앞 줄 앞의 창 하나. 돌려주는 줄은 앞에 붙일 것만이다. 총량 상한(거슬러 간 거리)에 닿았거나 처음까지 읽었으면 빈 쪽.
    /// **빈 쪽에 `hasEarlier`가 true여도 끝이 아니다**: 그 창이 건너뛴 줄뿐일 수 있다 — 다시 누르면 더 앞으로 간다
    public func earlier(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptLoad {
        guard cursor.earliestOffset > 0, cursor.coveredBytes < limits.maxTotalBytes else {
            return .page(ClaudeAppTranscriptPage(turns: [], cursor: cursor, hasEarlier: false, skippedLines: 0))
        }
        guard let entry = fileSystem.lstat(cursor.path), entry.kind == .regular, entry.owner == fileSystem.userID, entry.created == cursor.created, entry.size >= cursor.earliestOffset else {
            return .unreadable
        }
        // 한 번에 읽는 것은 창 하나, 거슬러 가는 거리는 남은 총량까지
        let length = Int(min(Int64(limits.windowBytes), Int64(limits.maxTotalBytes - cursor.coveredBytes), cursor.earliestOffset))
        let start = cursor.earliestOffset - Int64(length)
        guard let data = fileSystem.read(cursor.path, start, length), data.count == length else { return .unreadable }
        var next = cursor
        var peers = PeerSeen(ids: cursor.peerIDs)
        let scanned = scan(data, start: start, dropHead: start > 0, sessionID: cursor.sessionID, peers: &peers)
        next.peerIDs = peers.ids
        guard scanned.sawNewline else {
            // 창 전체가 한 줄 안이다: 그 줄은 건너뛰고 한 줄의 가운데에서 이어 간다
            next.earliestOffset = start
            next.coveredBytes += Int(cursor.earliestOffset - start)
            return .page(page(turns: [], cursor: next, skipped: data.isEmpty ? 0 : 1))
        }
        var (turns, earliest) = select(scanned)
        if earliest >= cursor.earliestOffset {
            // 창이 개행 하나뿐이라 나아가지 못했다: 이 창은 다 본 것으로 하고 가운데에서 이어 간다 (끝없이 같은 쪽을 돌려주지 않는다)
            earliest = start
            turns = []
        }
        next.earliestOffset = earliest
        next.coveredBytes += Int(cursor.earliestOffset - earliest)
        return .page(page(turns: turns, cursor: next, skipped: scanned.skipped))
    }

    /// 라이브 갱신: 지난번 끝 자리부터 새로 붙은 완성된 줄만. 개행이 오지 않은 줄은 기다린다. 파일이 줄었거나 다른 파일이면 `.reset`
    public func newer(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptUpdate {
        guard let entry = fileSystem.lstat(cursor.path), entry.kind == .regular, entry.owner == fileSystem.userID else {
            log.log("claude_app_transcript", ["result": .code("unreadable")])
            return .unreadable
        }
        if entry.created != cursor.created || entry.size < cursor.nextOffset {
            log.log("claude_app_transcript", ["result": .code("reset")])
            return .reset
        }
        if entry.size == cursor.nextOffset { return .turns([], cursor: cursor, hasMore: false) }
        let remaining = entry.size - cursor.nextOffset
        let length = Int(min(Int64(limits.windowBytes), remaining))
        guard let read = fileSystem.read(cursor.path, cursor.nextOffset, length) else {
            log.log("claude_app_transcript", ["result": .code("unreadable")])
            return .unreadable
        }
        var next = cursor
        var data = read
        var base = cursor.nextOffset
        if next.discarding {
            // 너무 긴 줄의 나머지: 개행까지 버린다
            guard let newline = data.firstIndex(of: 0x0A) else {
                next.nextOffset += Int64(data.count)
                return .turns([], cursor: next, hasMore: Int64(length) < remaining)
            }
            let skip = newline - data.startIndex + 1
            data = data.subdata(in: (data.startIndex + skip)..<data.endIndex)
            base += Int64(skip)
            next.discarding = false
        }
        var peers = PeerSeen(ids: cursor.peerIDs)
        let scanned = scan(data, start: base, dropHead: false, sessionID: cursor.sessionID, peers: &peers)
        next.peerIDs = peers.ids
        let leftover = data.count - scanned.consumedEnd
        if leftover > limits.maxLineBytes || (scanned.consumedEnd == 0 && data.count >= limits.windowBytes) {
            // 개행 없이 한 줄이 상한을 넘었다: 지금까지의 조각을 버리고 그 줄의 끝(개행)까지 계속 버린다
            next.nextOffset = base + Int64(data.count)
            next.discarding = true
        } else {
            next.nextOffset = base + Int64(scanned.consumedEnd)
        }
        return .turns(scanned.groups.flatMap(\.turns), cursor: next, hasMore: Int64(length) < remaining)
    }

    /// 펼친 도구 줄의 본문: 그 줄을 다시 읽어 입력을, 그 줄 뒤로 같은 `tool_use_id`의 결과를 찾는다 (각각 `maxDetailBytes`까지).
    /// 결과는 창 단위로 찾되 그 줄 뒤 **총량(`maxTotalBytes`) 안에서만** 찾는다: 그보다 먼 결과는 못 찾아 `result`가 nil이다 (입력은 준다). 창 경계에서 줄을 가르지 않는다.
    /// 도구 줄이 아니거나, 그 자리의 줄이 그 도구가 아니거나, 파일이 바뀌었으면 nil
    public func detail(of turn: ClaudeAppTurn, cursor: ClaudeAppTranscriptCursor) -> ClaudeAppToolDetail? {
        guard case .tool = turn.kind, let toolID = turn.toolUseID, turn.lineOffset >= 0,
              let entry = fileSystem.lstat(cursor.path), entry.kind == .regular, entry.owner == fileSystem.userID, entry.created == cursor.created, turn.lineOffset < entry.size else { return nil }
        let lineLength = Int(min(Int64(limits.maxLineBytes) + 1, entry.size - turn.lineOffset))
        guard let head = fileSystem.read(cursor.path, turn.lineOffset, lineLength), let newline = head.firstIndex(of: 0x0A), newline - head.startIndex <= limits.maxLineBytes else { return nil }
        let line = head.subdata(in: head.startIndex..<newline)
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["type"] as? String == "assistant",
              (object["sessionId"] as? String).map({ $0 == cursor.sessionID }) ?? true,
              let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]],
              let block = blocks.first(where: { $0["type"] as? String == "tool_use" && $0["id"] as? String == toolID }), let input = block["input"] else { return nil }
        var truncated = false
        let inputText = Self.render(input)
        let (shownInput, inputCut) = clean(inputText, limit: limits.maxDetailBytes)
        truncated = inputCut
        var result: String?
        var position = turn.lineOffset + Int64(line.count) + 1
        var searched = 0
        while result == nil, position < entry.size, searched < limits.maxTotalBytes {
            let length = Int(min(Int64(limits.windowBytes), entry.size - position, Int64(limits.maxTotalBytes - searched)))
            guard length > 0, let window = fileSystem.read(cursor.path, position, length) else { break }
            let split = Self.completeLines(window)
            if let found = Self.toolResult(in: window, spans: split.spans, toolID: toolID, sessionID: cursor.sessionID, maxLine: limits.maxLineBytes) {
                let (text, cut) = clean(found, limit: limits.maxDetailBytes)
                result = text
                truncated = truncated || cut
                break
            }
            // 다음 창은 마지막 완성된 줄 다음부터 (줄을 가르지 않는다). 개행이 하나도 없는 창(창보다 긴 줄)은 건너뛴다
            let advance = split.consumedEnd > 0 ? split.consumedEnd : window.count
            position += Int64(advance)
            searched += advance
            if window.count < length { break }
        }
        return ClaudeAppToolDetail(input: shownInput ?? "", result: result, truncated: truncated)
    }

    // MARK: 기록 찾기

    private struct Located {
        var path: String
        var entry: ExternalSessionFileSystem.Entry
    }

    /// 안전한 길로만 한 파일을 찾는다: `~/.claude`(realpath) · `projects` · 프로젝트 디렉터리 · 기록 파일 모두 기호 링크 아님 · 이 사용자 소유, 파일은 일반 파일.
    /// 같은 id가 두 디렉터리에 있으면 더 최근에 쓰인 것 (훑기와 같다)
    private func locate(sessionID: String, cwd: String?) -> Located? {
        let fs = fileSystem
        guard let rootEntry = fs.lstat(claudeDirectory), rootEntry.kind == .directory || rootEntry.kind == .symlink, let root = fs.realpath(claudeDirectory),
              let realRoot = fs.lstat(root), realRoot.kind == .directory, realRoot.owner == fs.userID else { return nil }
        let projects = root + "/projects"
        guard let projectsEntry = fs.lstat(projects), projectsEntry.kind == .directory, projectsEntry.owner == fs.userID, fs.realpath(projects) == projects else { return nil }

        func pick(_ names: [String]) -> Located? {
            var best: Located?
            for name in names {
                let directory = projects + "/" + name
                guard let directoryEntry = fs.lstat(directory), directoryEntry.kind == .directory, directoryEntry.owner == fs.userID, fs.realpath(directory) == directory else { continue }
                let path = directory + "/" + sessionID + ".jsonl"
                guard let file = fs.lstat(path), file.kind == .regular, file.owner == fs.userID else { continue }
                if let known = best, known.entry.modified >= file.modified { continue }
                best = Located(path: path, entry: file)
            }
            return best
        }

        if let cwd, ExternalSessionRules.isPlainAbsolutePath(cwd), let name = ExternalSessionRules.projectDirectoryName(forCwd: cwd), let found = pick([name]) { return found }
        // 폴더를 모르거나 맞지 않는다: `projects` 아래 디렉터리 이름만 훑어 그 id의 기록 이름을 확인한다 (다른 파일은 열지 않는다)
        guard case .entries(let directories) = fs.list(projects, ExternalSessionRegistry.maxListed + 1), directories.count <= ExternalSessionRegistry.maxListed else { return nil }
        let names = directories.filter { $0.kind == .directory && $0.owner == fs.userID && ExternalSessionReadAllowList.isProjectDirectory($0.name) }.map(\.name).sorted()
        return pick(names)
    }

    // MARK: 줄 읽기

    private struct Scanned {
        var groups: [(offset: Int64, turns: [ClaudeAppTurn])] = []
        var skipped = 0
        /// 완성된 첫 줄의 시작 (창이 줄 가운데에서 시작하면 그 조각 뒤)
        var firstLineStart: Int64 = 0
        /// 마지막 개행 바로 뒤 (창 안의 위치). 그 뒤는 아직 끝나지 않은 줄이다
        var consumedEnd = 0
        var sawNewline = false
    }

    private enum LineResult {
        case turns([ClaudeAppTurn])
        case failed
    }

    /// 이미 보여 준 peer 메시지의 열쇠 (최근 256개): 같은 메시지가 `user`와 `queued_command` 두 모양으로 기록돼도 한 번만 보인다.
    /// 열쇠는 `msg_id` 하나가 아니라 **(msg_id, 검증된 보낸 pid, 플러그인)** 셋이다: 다른 프로세스가 남의 msg_id를 흉내 내어 진짜 메시지를 가리지 못한다 (PR-D1 보안 검토 P3)
    struct PeerSeen {
        static let limit = 256
        var ids: [String] = []

        static func key(messageID: String, pid: Int32?, plugin: String?) -> String {
            "\(messageID)\u{1F}\(pid.map(String.init) ?? "")\u{1F}\(plugin ?? "")"
        }

        /// 처음 보는 열쇠(또는 msg_id가 없는 메시지)이면 true
        mutating func firstTime(_ key: String?) -> Bool {
            guard let key else { return true }
            if ids.contains(key) { return false }
            ids.append(key)
            if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
            return true
        }
    }

    /// 개행으로 나눈 완성된 줄(개행 앞)의 범위와 마지막 개행 뒤의 위치
    private static func completeLines(_ data: Data) -> (spans: [Range<Int>], consumedEnd: Int) {
        var spans: [Range<Int>] = []
        var lineStart = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var position = 0
            while position < buffer.count, let found = memchr(base + position, 0x0A, buffer.count - position) {
                let index = base.distance(to: UnsafeRawPointer(found))
                spans.append(lineStart..<index)
                lineStart = index + 1
                position = index + 1
            }
        }
        return (spans, lineStart)
    }

    /// 창 안의 완성된 줄들을 읽는다. 앞이 잘린 줄(`dropHead`)과 개행 없이 끝난 줄(창의 끝)은 읽지 않는다. 상한을 넘은 줄은 읽지 않고 센다
    private func scan(_ data: Data, start: Int64, dropHead: Bool, sessionID: String, peers: inout PeerSeen) -> Scanned {
        let split = Self.completeLines(data)
        var spans = split.spans
        var scanned = Scanned(firstLineStart: start, consumedEnd: split.consumedEnd, sawNewline: !spans.isEmpty)
        if dropHead {
            if let first = spans.first {
                scanned.firstLineStart = start + Int64(first.upperBound) + 1
                spans.removeFirst()
            } else {
                scanned.firstLineStart = start + Int64(data.count)
            }
        }
        let decoder = JSONDecoder()
        for span in spans where !span.isEmpty {
            if span.count > limits.maxLineBytes {
                scanned.skipped += 1
                continue
            }
            switch parse(data.subdata(in: span), offset: start + Int64(span.lowerBound), sessionID: sessionID, decoder: decoder, peers: &peers) {
            case .turns(let turns): if !turns.isEmpty { scanned.groups.append((start + Int64(span.lowerBound), turns)) }
            case .failed: scanned.skipped += 1
            }
        }
        return scanned
    }

    /// 쪽에 담을 줄: 끝에서부터 `pageTurns`개 이상이 될 때까지 줄 단위로 (한 줄의 칸을 가르지 않는다). 돌려주는 `earliest`는 담은 가장 앞 줄의 시작
    private func select(_ scanned: Scanned) -> (turns: [ClaudeAppTurn], earliest: Int64) {
        var index = scanned.groups.count
        var total = 0
        while index > 0, total < limits.pageTurns {
            index -= 1
            total += scanned.groups[index].turns.count
        }
        let earliest = index == 0 ? scanned.firstLineStart : scanned.groups[index].offset
        return (scanned.groups[index...].flatMap(\.turns), earliest)
    }

    private func page(turns: [ClaudeAppTurn], cursor: ClaudeAppTranscriptCursor, skipped: Int) -> ClaudeAppTranscriptPage {
        ClaudeAppTranscriptPage(turns: turns, cursor: cursor, hasEarlier: cursor.earliestOffset > 0 && cursor.coveredBytes < limits.maxTotalBytes, skippedLines: skipped)
    }

    private func finish(_ load: ClaudeAppTranscriptLoad) -> ClaudeAppTranscriptLoad {
        if case .page = load {
            log.log("claude_app_transcript", ["result": .code("ok")])
        } else {
            log.log("claude_app_transcript", ["result": .code("unreadable")])
        }
        return load
    }

    // MARK: 한 줄 해석

    private static let userNeedle = Data("\"user\"".utf8)
    private static let assistantNeedle = Data("\"assistant\"".utf8)
    private static let queuedNeedle = Data("\"queued_command\"".utf8)

    /// 디코딩하는 칸만 선언한다: `thinking` · 도구 입력 · 도구 결과 · 첨부 · 시스템 칸은 선언하지 않아 값으로 남지 않는다. 틀린 모양의 칸은 없는 것으로 읽는다
    private struct Record: Decodable {
        var type: String?
        var sessionId: String?
        var isMeta: Bool?
        var isSidechain: Bool?
        /// Claude Code가 대화를 줄여 넣은 요약 · 기록에서만 보이는 줄: 대화가 아니다
        var isCompactSummary: Bool?
        var isVisibleInTranscriptOnly: Bool?
        var timestamp: String?
        var message: Message?
        var origin: Origin?
        /// `origin` 키가 있다 (모양이 낯설어 디코딩하지 못해도): origin이 있는데 peer가 아니면 사용자가 친 말이 아니다
        var hasOrigin = false
        var attachment: Attachment?

        enum CodingKeys: String, CodingKey { case type, sessionId, isMeta, isSidechain, isCompactSummary, isVisibleInTranscriptOnly, timestamp, message, origin, attachment }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
            isMeta = try? container.decodeIfPresent(Bool.self, forKey: .isMeta)
            isSidechain = try? container.decodeIfPresent(Bool.self, forKey: .isSidechain)
            isCompactSummary = try? container.decodeIfPresent(Bool.self, forKey: .isCompactSummary)
            isVisibleInTranscriptOnly = try? container.decodeIfPresent(Bool.self, forKey: .isVisibleInTranscriptOnly)
            timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
            message = try? container.decodeIfPresent(Message.self, forKey: .message)
            origin = try? container.decodeIfPresent(Origin.self, forKey: .origin)
            hasOrigin = container.contains(.origin) && !((try? container.decodeNil(forKey: .origin)) ?? false)
            attachment = try? container.decodeIfPresent(Attachment.self, forKey: .attachment)
        }
    }

    private struct Message: Decodable {
        var content: Content?

        enum CodingKeys: String, CodingKey { case content }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = try? container.decodeIfPresent(Content.self, forKey: .content)
        }
    }

    private enum Content: Decodable {
        case text(String)
        case blocks([Block])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks(try container.decode([LossyBlock].self).compactMap(\.block))
            }
        }
    }

    private struct LossyBlock: Decodable {
        var block: Block?

        init(from decoder: Decoder) throws {
            block = try? Block(from: decoder)
        }
    }

    private struct Block: Decodable {
        var type: String?
        var text: String?
        var name: String?
        var id: String?
        var description: String?

        enum CodingKeys: String, CodingKey { case type, text, name, id, input }
        enum InputKeys: String, CodingKey { case description }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            text = try? container.decodeIfPresent(String.self, forKey: .text)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            // 도구 입력은 `description`만 꺼낸다 (명령 · 경로 · 내용은 담지 않는다)
            if let input = try? container.nestedContainer(keyedBy: InputKeys.self, forKey: .input) {
                description = try? input.decodeIfPresent(String.self, forKey: .description)
            }
        }
    }

    private struct Origin: Decodable {
        var kind: String?
        var plugin: String?
        var verifiedPeerPid: Int?
        var messageID: String?
        var body: String?

        enum CodingKeys: String, CodingKey { case kind, plugin, verifiedPeerPid, msg_id, body }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? container.decodeIfPresent(String.self, forKey: .kind)
            plugin = try? container.decodeIfPresent(String.self, forKey: .plugin)
            verifiedPeerPid = try? container.decodeIfPresent(Int.self, forKey: .verifiedPeerPid)
            messageID = try? container.decodeIfPresent(String.self, forKey: .msg_id)
            body = try? container.decodeIfPresent(String.self, forKey: .body)
        }
    }

    /// `attachment`는 `type`과 `origin`만 꺼낸다 (`prompt` · `rendered` · 계정 칸은 선언하지 않는다)
    private struct Attachment: Decodable {
        var type: String?
        var origin: Origin?

        enum CodingKeys: String, CodingKey { case type, origin }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            origin = try? container.decodeIfPresent(Origin.self, forKey: .origin)
        }
    }

    private func parse(_ line: Data, offset: Int64, sessionID: String, decoder: JSONDecoder, peers: inout PeerSeen) -> LineResult {
        // `"user"` · `"assistant"` · `"queued_command"` 글자가 하나도 없는 줄은 대화 줄이 될 수 없다: 디코딩하지 않는다.
        // 글자가 있는 줄은(계정 · 첨부 줄에 우연히 있을 수도 있다) 디코딩하되 `Record`가 선언한 칸만 꺼내고, 아래 규칙을 지나야 대화가 된다
        guard line.range(of: Self.userNeedle) != nil || line.range(of: Self.assistantNeedle) != nil || line.range(of: Self.queuedNeedle) != nil else { return .turns([]) }
        guard String(validating: line, as: UTF8.self) != nil, let record = try? decoder.decode(Record.self, from: line) else { return .failed }
        return .turns(turns(from: record, offset: offset, sessionID: sessionID, peers: &peers))
    }

    /// 사용자가 친 말이 아닌 Claude Code 표시 줄(슬래시 명령 · 로컬 명령 출력)의 시작
    private static let markupPrefixes = ["<command-name>", "<command-message>", "<command-args>", "<local-command-"]

    private func turns(from record: Record, offset: Int64, sessionID: String, peers: inout PeerSeen) -> [ClaudeAppTurn] {
        if record.isSidechain == true || record.isCompactSummary == true || record.isVisibleInTranscriptOnly == true { return [] }
        if let other = record.sessionId, other != sessionID { return [] }
        let time = record.timestamp.flatMap(Self.date)
        var out: [ClaudeAppTurn] = []
        func add(_ kind: ClaudeAppTurn.Kind, truncated: Bool = false, toolID: String? = nil) {
            out.append(ClaudeAppTurn(id: "\(offset)-\(out.count)", kind: kind, timestamp: time, truncated: truncated, lineOffset: offset, toolUseID: toolID))
        }
        func user(_ raw: String) {
            guard let (kept, cut) = plain(raw), !Self.markupPrefixes.contains(where: kept.hasPrefix) else { return }
            add(.user(kept), truncated: cut)
        }
        func peer(_ origin: Origin) {
            let messageID = origin.messageID.flatMap { $0.utf8.count <= 64 ? $0 : nil }
            let plugin = origin.plugin.flatMap { $0.utf8.count <= 64 ? $0 : nil }
            let pid = origin.verifiedPeerPid.flatMap { $0 > 0 && $0 <= Int(Int32.max) ? Int32($0) : nil }
            let key = messageID.map { PeerSeen.key(messageID: $0, pid: pid, plugin: plugin) }
            guard let body = origin.body, let (text, cut) = plain(body), peers.firstTime(key) else { return }
            add(.peer(text, ClaudeAppPeer(plugin: plugin, verifiedPeerPID: pid, messageID: messageID)), truncated: cut)
        }
        switch record.type {
        case "user":
            if let origin = record.origin, origin.kind == "peer" {
                peer(origin)
            } else if record.hasOrigin {
                // origin이 있는데 peer가 아니다(훅 · 작업 알림 등): 사용자가 친 말이 아니다
                break
            } else if record.isMeta != true, let content = record.message?.content {
                switch content {
                case .text(let text):
                    user(text)
                case .blocks(let blocks):
                    // 도구 결과 · 이미지 블록은 대화가 아니다: 텍스트 블록만 이어 붙인다
                    user(blocks.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n"))
                }
            }
        case "assistant":
            guard case .blocks(let blocks)? = record.message?.content else { return [] }
            for block in blocks {
                switch block.type {
                case "text":
                    if let text = block.text, let (kept, cut) = plain(text) { add(.assistant(kept), truncated: cut) }
                case "tool_use":
                    guard let name = block.name.flatMap(ExternalSessionRules.sanitizedTitle) else { continue }
                    add(.tool(name: name, description: block.description.flatMap(ExternalSessionRules.sanitizedTitle)), toolID: block.id.flatMap { $0.utf8.count <= 128 ? $0 : nil })
                default: continue
                }
            }
        case "attachment":
            if record.attachment?.type == "queued_command", let origin = record.attachment?.origin, origin.kind == "peer" { peer(origin) }
        default:
            break
        }
        return out
    }

    // MARK: 글 · 시각

    private func plain(_ raw: String) -> (String, Bool)? {
        let (text, cut) = clean(raw, limit: limits.maxTextBytes)
        return text.map { ($0, cut) }
    }

    /// 평문으로 정리한다 (DT8): 제어 글자(줄바꿈 · 탭 제외)와 눈에 보이지 않는 서식 글자(방향 바꿈 · 폭 없는 공백 · 연한 하이픈 · BOM · 태그 글자)와 줄 · 문단 구분(U+2028 · U+2029)을 지우고
    /// 앞뒤 공백을 자른다. 이모지 · 문자를 잇는 ZWJ · ZWNJ는 둔다. `limit` 바이트를 넘으면 글자 중간이 아닌 곳에서 자른다.
    /// 링크 · 태그 · 마크다운은 해석하지 않는다 — 글자 그대로다. 남는 것이 없으면 nil
    private func clean(_ raw: String, limit: Int) -> (String?, Bool) {
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        var truncated = false
        for scalar in raw.unicodeScalars {
            if Self.isStripped(scalar) { continue }
            let size = scalar.utf8.count
            if bytes + size > limit {
                truncated = true
                break
            }
            scalars.append(scalar)
            bytes += size
        }
        let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? nil : text, truncated)
    }

    private static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: return false
        // 글자를 잇는 데 쓰는 서식 글자 (ZWNJ · ZWJ)
        case 0x200C, 0x200D: return false
        case 0x2028, 0x2029: return true
        default:
            let category = scalar.properties.generalCategory
            return category == .control || category == .format
        }
    }

    private static func date(_ text: String) -> Date? {
        guard text.utf8.count <= 40 else { return nil }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    // MARK: 펼친 도구

    private static func render(_ input: Any) -> String {
        if let text = input as? String { return text }
        guard JSONSerialization.isValidJSONObject(input), let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) else {
            return String(describing: input)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 창 안에서 같은 `tool_use_id`의 결과 글을 찾는다 (`user` 줄의 `tool_result` 블록: 문자열이거나 텍스트 블록 배열)
    private static func toolResult(in window: Data, spans: [Range<Int>], toolID: String, sessionID: String, maxLine: Int) -> String? {
        let idNeedle = Data(toolID.utf8)
        let resultNeedle = Data("\"tool_result\"".utf8)
        for span in spans where !span.isEmpty && span.count <= maxLine {
            let line = window.subdata(in: span)
            guard line.range(of: resultNeedle) != nil, line.range(of: idNeedle) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["type"] as? String == "user",
                  (object["sessionId"] as? String).map({ $0 == sessionID }) ?? true,
                  let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in blocks where block["type"] as? String == "tool_result" && block["tool_use_id"] as? String == toolID {
                if let text = block["content"] as? String { return text }
                if let parts = block["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                return ""
            }
        }
        return nil
    }
}
#endif
