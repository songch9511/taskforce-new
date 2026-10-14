#if os(macOS)
import Foundation

/// 원장 파일 위치 (OA D2b 계약 2.5): `<Application Support>/<번들 id>/Bridge/v1/<파티션>/`.
/// 번들 id가 들어가므로 시험 호스트(`dev.taskforcelabs.unittest.taskforce`)와 실사용 앱이 섞이지 않고, 파티션에 서버 origin이 들어가므로 로컬 서버와 운영이 섞이지 않는다.
/// 시험은 뿌리 폴더를 주입한다 (실제 Application Support에 쓰지 않는다).
public enum BridgeStorage {
    public static func defaultRoot(bundleID: String, fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appending(path: bundleID, directoryHint: .isDirectory).appending(path: "Bridge", directoryHint: .isDirectory).appending(path: "v1", directoryHint: .isDirectory)
    }

    /// 이 파티션에 할 일이 남아 있나 (폴더가 없으면 false). 읽기 전용으로 열어 본다 — `BRIDGE_ENABLED`가 꺼졌을 때 마무리 모드가 필요한지 가르는 데 쓴다
    public static func hasPendingWork(partition: BridgePartition, root: URL) async -> Bool {
        let directory = partition.directory(in: root)
        guard FileManager.default.fileExists(atPath: directory.appending(path: "ledger.sqlite").path) else { return false }
        guard let ledger = try? BridgeLedger(directory: directory) else { return false }
        defer { Task { await ledger.close() } }
        return (try? await ledger.hasPendingWork()) ?? false
    }

    /// 계정 삭제 성공: 이 파티션의 원장 폴더와 Keychain 항목을 지운다 (Q22). 다른 파티션은 건드리지 않는다
    public static func deletePartition(_ partition: BridgePartition, root: URL, credentials: any BridgeCredentialStore) {
        try? FileManager.default.removeItem(at: partition.directory(in: root))
        try? credentials.deleteAll(partition: partition.id)
    }
}
#endif
