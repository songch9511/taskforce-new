import Foundation

// Settings › Your agents › Folders의 순수 규칙 (OA Settings › Your agents 7장): 프로젝트마다 연결된 작업 폴더 줄, Ungrouped 줄, 경로 표시(홈은 `~`, 가운데 줄임), 사라진 폴더.
// 등록부(`WorkspaceRegistry`)는 이 Mac의 사실이고 프로젝트 이름은 서버(`work_contexts`, RLS)다. 이 파일은 둘을 줄로 엮을 뿐 아무것도 쓰지 않는다.

/// 폴더 줄에 이름 · 아이콘을 대는 프로젝트 하나
public struct AgentFolderProject: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let icon: ProjectIconName

    public init(id: UUID, name: String, icon: ProjectIconName) {
        self.id = id
        self.name = name
        self.icon = icon
    }

    /// 읽은 범위에서: 보관된 프로젝트는 이름 뒤에 그렇게 적는다 (`WorkProject.title`)
    public init(_ context: WorkContext) {
        self.init(id: context.id, name: WorkProject(id: context.id, name: context.name, isArchived: context.status == .archived).title, icon: context.icon)
    }
}

/// 폴더 줄 하나. 프로젝트 줄은 `project`가 있고, 맨 끝 Ungrouped 줄은 없다
public struct AgentFolderLine: Equatable, Sendable, Identifiable {
    public let project: AgentFolderProject?
    /// 등록부의 realpath (Ungrouped는 nil)
    public let path: String?
    /// Value에 보이는 글: 경로(홈은 `~`, 길면 가운데 줄임) 또는 Ungrouped의 "Ask each time"
    public let display: String
    /// 폴더가 지금 없다 (굵은 "Missing"). 자동으로 지우지 않는다
    public let missing: Bool

    public var id: String { project?.id.uuidString ?? "ungrouped" }
    public var isUngrouped: Bool { project == nil }
    public var name: String { project?.name ?? AgentSettingsCopy.ungrouped }
}

public enum AgentSettingsFolders {
    /// 폴더가 있는 프로젝트마다 한 줄(이름 순), 맨 끝에 Ungrouped 한 줄 ("Ask each time", 컨트롤 없음).
    /// - folders: 등록부의 프로젝트 → 폴더
    /// - projects: 서버에서 읽은 프로젝트. **nil이면 아직 모른다**: 이름을 모르는 줄을 지어내지 않고(Ungrouped만), 아무것도 정리하지 않는다
    /// - homes: 홈으로 줄여 보일 경로들 (홈 · 홈의 realpath)
    /// - exists: 폴더가 지금 있나 (없으면 "Missing")
    /// 돌려주는 `orphans`는 읽은 프로젝트 목록에 없는 프로젝트의 폴더다 — 지워진 프로젝트의 폴더는 줄 대신 등록부에서 지울 정리 대상이다
    public static func lines(
        folders: [UUID: String], projects: [UUID: AgentFolderProject]?, homes: [String], exists: (String) -> Bool
    ) -> (lines: [AgentFolderLine], orphans: [UUID]) {
        var rows: [AgentFolderLine] = []
        var orphans: [UUID] = []
        if let projects {
            for (id, path) in folders {
                guard let project = projects[id] else {
                    orphans.append(id)
                    continue
                }
                rows.append(AgentFolderLine(project: project, path: path, display: AgentSettingsPath.display(path, homes: homes), missing: !exists(path)))
            }
        }
        rows.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        rows.append(AgentFolderLine(project: nil, path: nil, display: AgentSettingsCopy.askEachTime, missing: false))
        return (rows, orphans.sorted { $0.uuidString < $1.uuidString })
    }
}

/// 경로 표시 (7장): 홈은 `~`, 너무 길면 가운데를 줄임표로 (앞 · 뒤를 남긴다). 화면의 한 줄 Value도 가운데 줄임으로 맞춘다
public enum AgentSettingsPath {
    /// 이 길이를 넘으면 가운데를 줄인다 (글자 수). 화면 폭에 맞춘 줄임은 뷰가 따로 한다
    public static let maxLength = 96

    public static func display(_ path: String, homes: [String], limit: Int = maxLength) -> String {
        var shown = path
        // 더 긴 홈이 먼저다 (`/Users/a`와 `/Users/a/b`가 둘 다 있으면 가장 많이 줄이는 쪽)
        for home in homes.sorted(by: { $0.count > $1.count }) where !home.isEmpty && home != "/" {
            if path == home {
                shown = "~"
                break
            }
            if path.hasPrefix(home + "/") {
                shown = "~" + path.dropFirst(home.count)
                break
            }
        }
        return middleTruncated(shown, limit: limit)
    }

    /// `limit` 글자를 넘으면 앞 · 뒤를 남기고 가운데를 "…"로 (글자 단위: 이모지 · 한글을 쪼개지 않는다)
    public static func middleTruncated(_ text: String, limit: Int) -> String {
        let characters = Array(text)
        guard limit >= 3, characters.count > limit else { return text }
        let keep = limit - 1
        let head = keep / 2
        let tail = keep - head
        return String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
    }
}
