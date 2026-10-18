#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// `.command` 폴더 정리는 폴더를 검증하고 폴더 fd 기준으로 지운다 (Astra P2-4 · 보안 F4, 코디네이터 13.11): `Terminal`이 기호 링크로 바뀌어도 가리키는 곳의 파일을 지우지 않는다.
/// 실제 터미널 · `claude` 0: 임시 폴더만 쓴다
struct AgentTerminalCommandStoreDirectoryTests {
    /// 오래된 `.command` 파일이 든 폴더를 가리키는 `Terminal` 기호 링크
    private func linkedTerminal(_ temp: TempDirectory) throws -> (link: URL, victims: [URL], keeper: URL) {
        let elsewhere = temp.appending("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        var victims: [URL] = []
        for name in ["old-1.command", "old-2.command"] {
            let file = elsewhere.appending(path: name)
            try Data("echo precious".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: file.path)
            victims.append(file)
        }
        let keeper = elsewhere.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: keeper)
        let link = temp.appending("Terminal")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        return (link, victims, keeper)
    }

    @Test func aSymlinkedTerminalFolderSweepsNothingInTheFolderItPointsAt() throws {
        let temp = TempDirectory()
        let (link, victims, keeper) = try linkedTerminal(temp)
        #expect(AgentTerminalCommandStore(directory: link).sweep() == 0)
        for file in victims + [keeper] { #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)") }
    }

    @Test func aSymlinkedTerminalFolderRemovesNothingInTheFolderItPointsAtOnRemoveAll() throws {
        let temp = TempDirectory()
        let (link, victims, keeper) = try linkedTerminal(temp)
        #expect(AgentTerminalCommandStore(directory: link).removeAll() == 0)
        for file in victims + [keeper] { #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)") }
    }

    @Test func removeAllDeletesEveryCommandFileOfTheOwnerButNothingElse() throws {
        let temp = TempDirectory()
        let directory = temp.appending("Terminal")
        let store = AgentTerminalCommandStore(directory: directory)
        let fresh = try store.write("fresh")
        let second = try store.write("second")
        let other = directory.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: other)
        // `.command` 이름의 기호 링크는 따라가지 않는다
        let precious = temp.appending("precious")
        try Data("precious".utf8).write(to: precious)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "link.command"), withDestinationURL: precious)
        #expect(store.removeAll() == 2)
        #expect(!FileManager.default.fileExists(atPath: fresh.path) && !FileManager.default.fileExists(atPath: second.path), "아직 새 파일도 계정 삭제는 지운다")
        #expect(FileManager.default.fileExists(atPath: other.path) && FileManager.default.fileExists(atPath: precious.path))
        #expect(AgentTerminalCommandStore(directory: temp.appending("none")).removeAll() == 0, "폴더가 없어도 조용하다")
    }

    @Test func aFolderReplacedByASymlinkAfterTheStoreWasMadeIsStillNotFollowedByWrite() throws {
        let temp = TempDirectory()
        let directory = temp.appending("Terminal")
        let store = AgentTerminalCommandStore(directory: directory)
        _ = try store.write("first")
        // 폴더를 지우고 같은 이름의 기호 링크를 놓는다
        let elsewhere = temp.appending("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)
        #expect(throws: AgentTerminalCommandError.storeUnavailable) { try store.write("second") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }
}
#endif
