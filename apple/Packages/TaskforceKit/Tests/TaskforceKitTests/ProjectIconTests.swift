import Foundation
import Testing
@testable import TaskforceKit

/// 프로젝트 아이콘 · version 읽기 (U2-34 · F-4): `work_contexts.icon` · `version`을 읽고, 풀 밖 이름은 folder로 읽는다.
/// 서버 풀은 `src/lib/api/contract.ts` `PROJECT_ICON_POOL`(12종, 서버 head 12520ad · 마이그레이션 `20261117000000_context_icon_version.sql`)이다
struct ProjectIconTests {
    private func decode(_ json: String) throws -> WorkContext {
        try TaskforceJSON.decoder().decode(WorkContext.self, from: Data(json.utf8))
    }

    private func row(extra: String) -> String {
        #"{"id":"c0000000-0000-4000-8000-000000000001","name":"Taskforce 0.2.0","kind":"project","status":"active","context_version":3,"last_activity_at":"2026-10-14T01:00:00.000Z"\#(extra)}"#
    }

    @Test func thePoolIsTheServersTwelveInOrder() {
        #expect(ProjectIconName.pool.map(\.raw) == [
            "rocket", "briefcase", "flask-conical", "palette", "code-xml", "megaphone", "book-open", "building-2", "leaf", "compass", "target", "users",
        ])
        #expect(ProjectIconName.pool.count == 12)
    }

    @Test func aNameOutsideThePoolReadsAsFolder() {
        #expect(ProjectIconName(raw: "rocket") == .rocket)
        #expect(ProjectIconName(raw: "compass") == .compass)
        #expect(ProjectIconName(raw: "hologram") == .folder)
        #expect(ProjectIconName(raw: "") == .folder)
        #expect(ProjectIconName(raw: nil) == .folder)
        #expect(ProjectIconName.folder.raw == "folder")
        #expect(!ProjectIconName.pool.contains(.folder), "folder는 풀에 없다")
    }

    @Test func theReadAsksForIconAndVersionAndTheOldColumnsRemainAsAFallback() {
        #expect(WorkContext.columns == "id, name, kind, status, context_version, last_activity_at, icon, version")
        #expect(WorkContext.columnsWithoutIcon == "id, name, kind, status, context_version, last_activity_at")
    }

    @Test func aRowReadsItsIconAndVersion() throws {
        let context = try decode(row(extra: #","icon":"rocket","version":4"#))
        #expect(context.icon == .rocket && context.version == 4 && context.contextVersion == 3)
    }

    @Test func aRowWithoutTheColumnsStillReads() throws {
        // 마이그레이션 전 DB의 응답: 아이콘은 folder, version은 모른다 (멤버십 읽기는 그대로 된다)
        let context = try decode(row(extra: ""))
        #expect(context.icon == .folder && context.version == nil && context.name == "Taskforce 0.2.0")
        let odd = try decode(row(extra: #","icon":"hologram","version":"x""#))
        #expect(odd.icon == .folder && odd.version == nil, "모양이 어긋난 값이 목록 전체를 못 읽게 하지 않는다")
    }

    @Test func theOldConstructorStillWorks() {
        let context = WorkContext(id: UUID(), name: "Shape launch", status: .active, contextVersion: 3)
        #expect(context.icon == .folder && context.version == nil)
        let with = WorkContext(id: UUID(), name: "Shape launch", icon: .megaphone, version: 2)
        #expect(with.icon == .megaphone && with.version == 2)
    }
}
