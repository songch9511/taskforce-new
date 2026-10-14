#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 원장 위치 · 계정 삭제 정리 (OA D2b 계약 2.5 · 2.13-5 · Q22)
struct BridgeStorageTests {
    @Test func theDefaultRootIsUnderApplicationSupportPerBundleID() throws {
        let root = try #require(BridgeStorage.defaultRoot(bundleID: "dev.taskforcelabs.unittest.taskforce"))
        #expect(root.path.hasSuffix("/dev.taskforcelabs.unittest.taskforce/Bridge/v1"))
        let production = try #require(BridgeStorage.defaultRoot(bundleID: "dev.taskforcelabs.taskforce"))
        #expect(root != production, "시험 호스트와 실사용 앱이 섞이지 않는다")
    }

    @Test func pendingWorkIsReadWithoutCreatingAnythingForAMissingPartition() async throws {
        let dir = TempDirectory()
        let partition = BridgePartition(apiOrigin: "http://x", userID: UUID())
        #expect(await BridgeStorage.hasPendingWork(partition: partition, root: dir.url) == false)
        #expect(!FileManager.default.fileExists(atPath: partition.directory(in: dir.url).path), "읽기만 하고 폴더를 만들지 않는다")
        let ledger = try BridgeLedger(directory: partition.directory(in: dir.url))
        try await ledger.saveCommand(BridgeTest.command(state: .leased))
        await ledger.close()
        #expect(await BridgeStorage.hasPendingWork(partition: partition, root: dir.url))
    }

    private struct FailingCredentials: BridgeCredentialStore {
        func deviceID(partition: String) throws -> String? { nil }
        func secret(partition: String) throws -> String? { nil }
        func save(deviceID: String, partition: String) throws {}
        func save(secret: String, partition: String) throws {}
        func deleteAll(partition: String) throws { throw BridgeLedgerError.corrupt }
    }

    @Test func aCleanupThatCouldNotRemoveTheCredentialsSaysSo() async throws {
        let dir = TempDirectory()
        let partition = BridgePartition(apiOrigin: "https://x.test", userID: UUID())
        let ledger = try BridgeLedger(directory: partition.directory(in: dir.url))
        await ledger.close()
        let result = await BridgeStorage.deletePartition(partition, root: dir.url, credentials: FailingCredentials())
        #expect(result.folderRemoved && !result.credentialsRemoved && !result.isComplete, "남은 것을 알린다 (사용자 데이터가 남았는데 성공으로 보이지 않게)")
        #expect(!FileManager.default.fileExists(atPath: partition.directory(in: dir.url).path))
    }

    @Test func aCleanupWithARunningAgentLeftBehindIsNotComplete() async throws {
        let dir = TempDirectory()
        let partition = BridgePartition(apiOrigin: "https://x.test", userID: UUID())
        let ledger = try BridgeLedger(directory: partition.directory(in: dir.url))
        await ledger.close()
        let result = await BridgeStorage.deletePartition(partition, root: dir.url, credentials: InMemoryBridgeCredentialStore(), unterminatedProcesses: 2)
        #expect(result.folderRemoved && result.credentialsRemoved, "사용자 데이터는 그래도 지운다")
        #expect(result.unterminatedProcesses == 2 && !result.isComplete, "끝내지 못한 프로세스가 남았다는 것을 알린다 (검토 반영 2 8장 6)")
        let clean = await BridgeStorage.deletePartition(partition, root: dir.url, credentials: InMemoryBridgeCredentialStore())
        #expect(clean.unterminatedProcesses == 0 && clean.isComplete)
    }

    @Test func deletingAPartitionRemovesItsFolderAndCredentialsOnly() async throws {
        let dir = TempDirectory()
        let credentials = InMemoryBridgeCredentialStore()
        let mine = BridgePartition(apiOrigin: "http://x", userID: UUID())
        let other = BridgePartition(apiOrigin: "http://x", userID: UUID())
        for partition in [mine, other] {
            let ledger = try BridgeLedger(directory: partition.directory(in: dir.url))
            try await ledger.saveCommand(BridgeTest.command())
            await ledger.close()
            try credentials.save(deviceID: "device-\(partition.id)", partition: partition.id)
            try credentials.save(secret: "secret-\(partition.id)", partition: partition.id)
        }
        let result = await BridgeStorage.deletePartition(mine, root: dir.url, credentials: credentials)
        #expect(result.isComplete, "둘 다 지웠으면 완료")
        #expect(!FileManager.default.fileExists(atPath: mine.directory(in: dir.url).path))
        #expect(try credentials.deviceID(partition: mine.id) == nil)
        #expect(try credentials.secret(partition: mine.id) == nil)
        #expect(FileManager.default.fileExists(atPath: other.directory(in: dir.url).path))
        #expect(try credentials.deviceID(partition: other.id) != nil)
    }
}
#endif
