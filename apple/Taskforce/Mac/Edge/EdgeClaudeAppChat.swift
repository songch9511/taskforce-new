#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// 데스크톱 세션과의 대화 (OA PR-D3m, 계약 25장 · DZ 승인 2026-10-22 `oa-desktop-rail-dz` 시트 3 · 4 · 5): Claude 세션 패널의 입력창 · 첫 보내기 확인(C5) · 전달 줄 · 실패 이유 · peer 줄 밑의 표시.
// 판정(보내기 전 확인 · 중계 · 전달 상태 · 저장)은 Kit(`ClaudeAppChatService`)이 하고 여기는 이 Mac의 값을 대는 일과 그리기뿐이다.
// **`ClaudeAppRelayGate`가 꺼진 빌드(Release)에는 이 파일의 어느 것도 만들어지지 않는다** — 세션 보기는 읽기 전용 그대로다. 글 · 세션 id · 경로를 로그에 남기지 않는다.

/// 이 Mac의 실제 값으로 대화 흐름을 만든다 (게이트 ∧ 서비스 · 계정 경계가 있을 때만)
@MainActor
enum ClaudeAppChatRuntime {
    /// 이 실행에서 켜졌나: Debug · 내부 배포 빌드만 (Release는 늘 꺼짐, 계약 25.7). 사용자 L 확인 ①–⑥ + 보안 검토 뒤에 출시 빌드에서 켠다
    static var enabledForThisRun: Bool {
        ClaudeAppRelayGate.isEnabled(isDebugBuild: EdgeSurfaces.isDebugBuild, isInternalBuild: InternalBuildFlag.isEnabled(info: Bundle.main.infoDictionary))
    }

    /// 앱 번들 안 mod 폴더: `Taskforce.app/Contents/Resources/tf-relay` (서명된 번들 안 읽기 전용, 해시는 띄우기 전에 `ClaudeAppRelayMod`가 본다)
    static func modDirectory(bundle: Bundle = .main) -> String {
        (bundle.resourceURL ?? bundle.bundleURL).appending(path: "tf-relay", directoryHint: .isDirectory).path
    }

    /// 앱 데이터 안 중계의 자리: cwd(빈 폴더) · 지킴이가 끝을 증명해 쓰는 파일. 번들 id 아래라 시험 호스트는 실사용 앱의 폴더를 쓰지 않는다
    static func relayFolders(bundle: Bundle = .main, supportDirectory: URL? = nil) -> (work: String, ended: URL)? {
        guard let bundleID = bundle.bundleIdentifier, let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let base = support.appending(path: bundleID, directoryHint: .isDirectory).appending(path: "claude-app-relay", directoryHint: .isDirectory)
        return (base.appending(path: "cwd", directoryHint: .isDirectory).path, base.appending(path: "relay.ended"))
    }

    /// 중계 (프로세스는 처음 쓸 때까지 뜨지 않는다). 폴더를 정할 수 없으면 nil
    static func makeRelay(home: String, log: any BridgeLogSink, bundle: Bundle = .main) -> ClaudeAppRelay? {
        guard let folders = relayFolders(bundle: bundle) else { return nil }
        let launcher = LocatingClaudeAppRelayLauncher(locator: .standard(home: home), keeper: ClaudeCodeHelpers.inBundle(bundle).keeper, endedFile: folders.ended)
        return ClaudeAppRelay(
            configuration: ClaudeAppRelay.Configuration(modDirectory: modDirectory(bundle: bundle), workDirectory: folders.work), launcher: launcher, log: log, pids: .shared
        )
    }

    /// 저장 켜짐 확인(`GET claude-app-chats/status`)을 기다리는 최대 시간
    nonisolated static let statusTimeout: TimeInterval = 5

    /// 저장 쪽: 저장이 켜졌는지(`GET claude-app-chats/status`)와 올리기(`PUT claude-app-chats`)를 서버 API에 잇는다. 서버를 부르는 것은 `ensureAsked()`부터다
    static func makeSaver(
        api: APIClient, log: any BridgeLogSink, sleep: @escaping ClaudeAppChatSaver.Sleep = { try? await Task.sleep(for: .seconds($0)) }
    ) -> ClaudeAppChatSaver {
        ClaudeAppChatSaver(
            // 짧은 시간 제한: 서버가 느려도 교환을 모으는 쪽이 오래 기다리지 않는다 (넘으면 모르는 답: 저장은 켜지 않고 1분 뒤 다시 묻는다, OA PR-D3 검토 P2-3)
            status: { try await ClaudeAppChatSaver.timed(seconds: statusTimeout) { try await api.claudeAppChatsStatus() } },
            put: { request in
                do {
                    return .saved(chatID: try await api.putClaudeAppChat(request).chatID)
                } catch {
                    return ClaudeAppChatUploader.outcome(for: error)
                }
            },
            sleep: sleep, log: log
        )
    }

    /// 대화 흐름: 사실 모으기 · 기록 읽기 · 저장 · 지표를 이 Mac의 값으로 잇는다. 계정이 떠나면 하던 일을 끝내고 입력 상태를 버린다.
    /// 서버를 부르는 것은 처음 글을 보낼 때부터다 (그 앞에는 저장 켜짐 확인도 지표도 없다)
    static func makeService(
        relay: ClaudeAppRelay, api: APIClient, scope: AccountScope, desktop: ClaudeAppSessionsModel, externalSessions: ExternalSessionsStore?, home: String, log: any BridgeLogSink
    ) -> ClaudeAppChatService {
        let verifier = ClaudeAppSendVerifier(sessionsDirectory: home + "/.claude/sessions", ownPIDs: { ClaudeAppRelayPIDs.shared.current })
        let saver = makeSaver(api: api, log: log)
        let identities = ExternalSessionsEnvironment(host: { BridgeHost.shared }, home: home)
        let service = ClaudeAppChatService(
            environment: ClaudeAppChatEnvironment(
                relay: relay, facts: { verifier.facts(for: $0) }, transcript: ClaudeAppTranscriptReader(claudeDirectory: home + "/.claude", log: log),
                session: { [weak desktop] id in desktop?.session(id: id) }, saver: saver,
                identity: { id in
                    let title = await MainActor.run { externalSessions?.rows.first { $0.id == id }?.title }
                    return await identities.chatIdentity(sessionID: id, title: title)
                },
                report: { report in
                    do { try await api.claudeAppSent(report) } catch { log.log("claude_app_sent_metric", ["result": .code("failed")]) }
                },
                log: log
            )
        )
        scope.onLeft { Task { await service.accountLeft() } }
        return service
    }
}

/// 입력창 자리가 무엇을 보이나 (순수한 판단: 시험이 상태마다 확인한다, DZ 시트 2 · 3 · 4 · 5).
/// 위에서부터: 첫 보내기 확인 카드(C5) → 띠(승인 · 답을 기다릴 때, **Open in Claude 단추뿐 · Approve · Deny 없음**) → 입력창.
/// 닫힘 · 기록 못 읽음에는 입력창이 없다. 띠가 있어도 입력창은 열려 있다 (기다리는 동안 보낸 말은 Queued)
struct ClaudeAppFooterPlan: Equatable {
    var confirm: Bool
    var band: ClaudeAppPanelBand?
    var composer: Bool

    /// 띠가 가진 단추의 글자: Taskforce는 어느 질문 · 권한에도 답하지 않는다 (DR-S2e)
    static let bandButtons = [ClaudeAppCopy.openInClaude]

    /// - chat: 이 빌드에 대화 흐름이 없으면(Release) nil: 입력창 · 확인 카드가 없다
    static func of(band: ClaudeAppPanelBand?, chat: (composerShown: Bool, isConfirming: Bool)?) -> ClaudeAppFooterPlan {
        let shown = chat?.composerShown ?? false
        return ClaudeAppFooterPlan(confirm: shown && chat?.isConfirming == true, band: band, composer: shown)
    }
}

/// 입력창 · 확인 카드 · 띠 (Claude 세션 패널 아래). 새 부품 없음: `Composer` · `ConfirmCard` · `Notice`
struct ClaudeAppFooterView: View {
    @Bindable var shell: EdgeShellModel
    let sessionID: String
    let band: ClaudeAppPanelBand?
    let chat: ClaudeAppSessionChat?
    var canSubmit: () -> Bool = { true }
    var claimsFocusOnCreation = true

    var body: some View {
        let plan = ClaudeAppFooterPlan.of(band: band, chat: chat.map { ($0.composerShown, $0.isConfirming) })
        VStack(spacing: 0) {
            if plan.confirm, let chat {
                ConfirmCard(
                    title: ClaudeAppChatCopy.confirmTitle, detail: ClaudeAppChatCopy.confirmDetail, confirmLabel: ClaudeAppChatCopy.confirmSend, cancelLabel: ClaudeAppChatCopy.confirmCancel,
                    autoFocus: true, onConfirm: { chat.confirm() }, onCancel: { chat.cancelConfirmation() }
                )
                .padding(EdgeInsets(top: TFSpace.sm, leading: TFSpace.md, bottom: 0, trailing: TFSpace.md))
            }
            if let band = plan.band {
                Notice(icon: band == .approve ? .execution : .talk, title: band.title) {
                    // 단추는 `bandButtons`가 정한 글자 그대로이고 모두 Claude 앱을 앞으로 가져올 뿐이다 (어느 질문 · 권한에도 답하지 않는다)
                    ForEach(ClaudeAppFooterPlan.bandButtons, id: \.self) { title in
                        Button(title) { shell.openDesktopInClaude(sessionID) }.buttonStyle(TFButtonStyle(.secondary, size: .sm))
                    }
                }
                .padding(EdgeInsets(top: TFSpace.sm, leading: TFSpace.md, bottom: plan.composer ? 0 : TFSpace.md, trailing: TFSpace.md))
            }
            if plan.composer, let chat {
                composer(chat)
            } else if plan.band == nil {
                Color.clear.frame(height: TFSpace.sm)
            }
        }
    }

    private func composer(_ chat: ClaudeAppSessionChat) -> some View {
        Composer(
            text: Binding(get: { chat.draft }, set: { if canSubmit() { chat.draft = $0 } }), placeholder: ClaudeAppChatCopy.composerPlaceholder, label: ClaudeAppChatCopy.composerLabel,
            // 확인 전 글이 있거나 확인 중이면 Send가 꺼진다 (글을 계속 쓸 수는 있다)
            isSending: chat.hasPending || chat.isChecking || chat.isConfirming, claimsFocusOnCreation: claimsFocusOnCreation, onSubmit: { _ in if canSubmit() { chat.submit() } }
        )
        .padding(EdgeInsets(top: 10, leading: TFSpace.md, bottom: TFSpace.md, trailing: TFSpace.md))
    }
}

/// 아직 대화 기록에 나타나지 않은 보낸 말 (Sending… · Sent · Queued · Not sent): 말풍선 + 전달 줄. 기록에서 확인되어 그 줄이 보이면(Received) 이 말풍선은 사라지고 기록의 줄이 그 자리를 이어받는다
struct ClaudeAppDeliveryBubbles: View {
    let chat: ClaudeAppSessionChat
    /// 지금 화면에 있는 대화 줄 id (확인된 말의 기록 줄이 보이면 이 말풍선을 감춘다)
    let shownTurnIDs: Set<String>

    static func visible(_ deliveries: [ClaudeAppSessionChat.Delivery], shownTurnIDs: Set<String>) -> [ClaudeAppSessionChat.Delivery] {
        deliveries.filter { delivery in
            guard delivery.state == .received, let matched = delivery.matchedTurnID else { return true }
            return !shownTurnIDs.contains(matched)
        }
    }

    var body: some View {
        let shown = Self.visible(chat.deliveries, shownTurnIDs: shownTurnIDs)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: TFSpace.md) {
                ForEach(shown) { delivery in
                    VStack(alignment: .leading, spacing: 0) {
                        Message(isUser: true) { MessageText(delivery.text) }
                        MessageDeliveryView(delivery.line, onLink: { link in
                            if case .sendAgain = link.kind { chat.sendAgain(delivery.id) }
                        })
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.top, TFSpace.md)
        }
    }
}
/// Only the selected task identity accompanies the user's message; transcripts stay local.
enum AgentTreeContextMessage {
    static func make(task: TaskforceKit.BackgroundTask, text: String) -> String? {
        let message = ChatComposerRules.normalized(text)
        guard !message.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["agent_id": task.id, "task": task.title], options: [.sortedKeys]),
              let identity = String(data: data, encoding: .utf8) else { return nil }
        let payload = "Regarding this sub-agent task (context only):\n\(identity)\n\nUser message:\n\(message)"
        guard ChatComposerRules.isSendable(payload), ClaudeAppSendText.normalize(payload) != nil else { return nil }
        return payload
    }
}

struct AgentTreeContextComposer: View {
    let task: TaskforceKit.BackgroundTask
    @Binding var text: String
    var unavailable: String? = nil
    var isSending = false
    var onOpenMain: () -> Void
    var onSubmit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.xs) {
            Label("To Main", systemImage: "arrow.turn.up.right")
                .font(TFFont.caption).foregroundStyle(TFColor.textSecondary)
                .help("Includes the context of \(task.title)")
            if let unavailable {
                Text(unavailable).font(TFFont.footnote)
                Button("View Main conversation", action: onOpenMain)
                    .buttonStyle(TFButtonStyle(.secondary, size: .sm))
            }
            Composer(
                text: $text, placeholder: "Message Main…", label: "Message Main about \(task.title)",
                isDisabled: unavailable != nil, isSending: isSending,
                claimsFocusOnCreation: false,
                sendEnabled: AgentTreeContextMessage.make(task: task, text: text) != nil,
                onSubmit: { text in
                    guard unavailable == nil, let payload = AgentTreeContextMessage.make(task: task, text: text) else { return }
                    onSubmit(payload)
                }
            )
            if !ChatComposerRules.normalized(text).isEmpty && AgentTreeContextMessage.make(task: task, text: text) == nil {
                Text("Shorten this message to include the task context.").font(TFFont.footnote)
            }
        }
        .padding(TFSpace.lg)
    }
}
#endif
