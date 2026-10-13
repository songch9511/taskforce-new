import Foundation

/// 테스트가 쓰는 UserDefaults. 테스트 호스트의 `UserDefaults.standard`(= 호스트 번들 ID의 설정 도메인)와 `~/Library/Preferences`를 쓰지 않는다.
///
/// - 임시 폴더 안의 plist만 쓰는 suite다 (절대 경로 suite 이름): 테스트마다 새 폴더, 비어 있는 상태로 시작한다.
/// - `cleanup()`은 값과 폴더를 지운다. 몇 번 불러도 같고 `deinit`도 부르지만, 테스트는 `defer { store.cleanup() }`로 정상 종료 · 실패 모두에서 지운다
///   (Swift가 마지막 사용 뒤에 객체를 먼저 놓을 수 있어서 `defer`가 확실하다).
/// - 이름 있는 suite(`UserDefaults(suiteName: "이름")`)는 값을 지워도 `~/Library/Preferences`에 빈 plist가 남으므로 테스트에서 쓰지 않는다.
final class TestDefaults {
    let defaults: UserDefaults
    let directory: URL
    private let suiteName: String

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaskforceTestDefaults-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = directory.appending(path: "defaults").path
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        self.directory = directory
        self.suiteName = suiteName
        self.defaults = defaults
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    deinit {
        cleanup()
    }
}
