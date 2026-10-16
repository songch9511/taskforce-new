import Foundation

// Assistant 창의 맥락 칩 (OA U1, DS ContextChip · PromptBox). "이 메시지가 무엇을 볼 수 있나"를 보이는 칩이다.
// - auto: 패널에 열린 항목. **메시지를 보낼 때까지 따라다니고**, 보낸 뒤에는 added로 남는다. 점선 칩
// - added: 사용자가 더한 것 (Ask · 끌어놓기 · Attach는 U2 · DZ 뒤). 채운 칩
// - 제거(×)는 auto도 되고 이 대화에서 유지된다. 최대 20개, 개수는 화면에 보이지 않는다
// - 에이전트 대상이면 auto 칩은 보내지 않는다: 점선 그대로 " · Not sent"가 붙는다 (보낼지는 서버가 정한다, 앱은 모든 칩을 origin과 함께 싣는다).
//   그 칩을 사용자가 누르면 added가 된다 (`promote`, OA D4a-12): 꼬리가 없어지고 면이 채워지고 보낼 칩이 된다

/// 칩 하나. 이름은 항목의 이름 (이슈는 번호가 앞)
public struct AssistantChip: Identifiable, Equatable, Sendable {
    public let kind: ChatAttachmentKind
    public let itemID: UUID
    public var origin: ChatAttachmentOrigin
    public let title: String
    /// 이슈 번호 (아직 읽는 길이 없으면 nil)
    public let number: Int?

    public init(kind: ChatAttachmentKind, itemID: UUID, origin: ChatAttachmentOrigin, title: String, number: Int? = nil) {
        self.kind = kind
        self.itemID = itemID
        self.origin = origin
        self.title = title
        self.number = number
    }

    /// 같은 항목은 같은 칩 (종류 + id)
    public var id: String { "\(kind.raw):\(itemID.uuidString.lowercased())" }

    /// "#139 Rewrite pricing page copy" (번호가 없으면 이름만)
    public var label: String {
        number.map { "#\($0) \(title)" } ?? title
    }

    /// 자리표시에 쓰는 이름: 이슈는 번호, 없으면 이름
    var placeholderName: String {
        number.map { "#\($0)" } ?? title
    }

    public var attachment: ChatAttachment {
        ChatAttachment(kind: kind, id: itemID, origin: origin)
    }
}

/// 한 대화의 칩들 (창마다 하나)
public struct AssistantChipSet: Equatable, Sendable {
    public static let capacity = 20
    public static let notSentSuffix = " · Not sent"

    public private(set) var chips: [AssistantChip] = []
    /// 사용자가 뺀 auto 칩: 이 대화에서는 같은 항목이 다시 auto로 돌아오지 않는다
    private var dismissed: Set<String> = []

    public init() {}

    public var isFull: Bool { chips.count >= Self.capacity }

    /// 패널에서 지금 열린 항목을 auto 칩이 따라간다. nil(열린 항목이 없음)이면 그대로 둔다.
    /// 이미 칩인 항목 · 뺀 항목은 다시 만들지 않는다. auto 칩은 하나뿐이라 다른 항목을 열면 그 자리에서 바뀐다
    public mutating func follow(_ item: AssistantChip?) {
        guard var item else { return }
        item.origin = .auto
        guard !dismissed.contains(item.id), !chips.contains(where: { $0.id == item.id }) else { return }
        if let index = chips.firstIndex(where: { $0.origin == .auto }) {
            chips[index] = item
        } else if !isFull {
            chips.append(item)
        }
    }

    /// 사용자가 더한 칩. 이미 있는 항목이면 added로 올린다. 가득 차면 false
    @discardableResult
    public mutating func add(_ chip: AssistantChip) -> Bool {
        var chip = chip
        chip.origin = .added
        if let index = chips.firstIndex(where: { $0.id == chip.id }) {
            chips[index].origin = .added
            return true
        }
        guard !isFull else { return false }
        chips.append(chip)
        return true
    }

    /// 에이전트 대상에서 auto 칩을 눌렀다 (OA D4a-12, 계약 v3 2.3): added가 된다. 이미 added거나 없는 칩이면 false
    @discardableResult
    public mutating func promote(_ id: String) -> Bool {
        guard let index = chips.firstIndex(where: { $0.id == id }), chips[index].origin == .auto else { return false }
        chips[index].origin = .added
        return true
    }

    /// × : auto도 뺄 수 있고, 뺀 auto는 이 대화에서 다시 따라오지 않는다
    public mutating func remove(_ id: String) {
        guard let index = chips.firstIndex(where: { $0.id == id }) else { return }
        if chips[index].origin == .auto { dismissed.insert(id) }
        chips.remove(at: index)
    }

    /// 메시지를 보냈다: Taskforce로 보낸 auto 칩은 added로 남는다. 에이전트로는 auto 칩이 가지 않았으니 auto 그대로다
    public mutating func didSend(toAgent: Bool) {
        guard !toAgent else { return }
        for index in chips.indices where chips[index].origin == .auto { chips[index].origin = .added }
    }

    /// 보낼 때 싣는 칩 전부 (순서 · origin 그대로). auto를 에이전트로 실제 보낼지는 서버가 정한다
    public var attachments: [ChatAttachment] { chips.map(\.attachment) }

    /// 칩에 보이는 이름: 에이전트 대상이면 auto 칩 끝에 " · Not sent"
    public func label(for chip: AssistantChip, toAgent: Bool) -> String {
        toAgent && chip.origin == .auto ? chip.label + Self.notSentSuffix : chip.label
    }
}

/// 프롬프트 박스의 글 (DS PromptBox · Assistant window "Empty")
public enum AssistantPromptRules {
    public static let blockedDefault = "Answer the question above first"
    /// 이름 없는 새 대화의 머리 제목 (DS Chats = the one name, ChatCopy.newChat과 같은 말)
    public static let untitled = "New chat"

    /// 자리표시. 비밀 질문이 열려 있으면(`blocked`) 이유가 이긴다. 에이전트 대상은 "Message <이름>",
    /// Taskforce는 칩이 없으면 "Ask Taskforce", 하나면 "Ask about <그 이름>", 여럿이면 "Ask about these"
    public static func placeholder(chips: [AssistantChip], target: AssistantTargetPick, targetName: String, blocked: String?) -> String {
        if let blocked { return blocked.isEmpty ? blockedDefault : blocked }
        if target.isAgent { return "Message \(targetName)" }
        switch chips.count {
        case 0: return "Ask Taskforce"
        case 1: return "Ask about \(chips[0].placeholderName)"
        default: return "Ask about these"
        }
    }
}
