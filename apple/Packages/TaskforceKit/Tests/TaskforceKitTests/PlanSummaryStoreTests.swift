import Foundation
import Testing
@testable import TaskforceKit

/// Plan & usage의 상태 · 동작 (OA 결제 계약 9.1 · 9.3 · 16.4): 서버 길은 가짜, 주소는 열지 않고 기록만 한다
@MainActor
struct PlanSummaryStoreTests {
    typealias F = PlanFixtures
    let user = UUID(uuidString: "a1111111-1111-4111-8111-111111111111")!
    let other = UUID(uuidString: "b2222222-2222-4222-8222-222222222222")!

    private func make(
        _ gateway: FakePlanGateway, user: UUID? = nil, settleReads: Int = 3, pauses: PauseCounter = PauseCounter(), account: AccountBox? = nil
    ) -> (PlanSummaryStore, OpenedURLs) {
        let store = PlanSummaryStore(clock: { F.now }, calendar: F.calendar, pause: { _ in pauses.tick() }, settleReads: settleReads, settleInterval: .seconds(1))
        let opened = OpenedURLs()
        store.opener = { opened.record($0) }
        var provider: (@MainActor () -> UUID?)?
        if let account { provider = { account.id } }
        store.follow(userID: user ?? self.user, gateway: gateway, currentAccount: provider)
        return (store, opened)
    }

    // MARK: 읽기

    @Test func refreshReadsTheStatusOnceAndTheStateShowsIt() async {
        let gateway = FakePlanGateway(status: F.pro)
        let (store, _) = make(gateway)
        #expect(store.state.row("plan")?.control == .value("Checking…", bold: false), "읽기 전")
        await store.refresh()
        #expect(gateway.calls == ["status"])
        #expect(store.state.row("plan")?.control == .value("Pro · Monthly · $12.99 a month", bold: false))
    }

    @Test func withoutAnAccountNothingIsRead() async {
        let gateway = FakePlanGateway(status: F.pro)
        let store = PlanSummaryStore()
        await store.refresh()
        store.follow(userID: nil, gateway: gateway)
        await store.refresh()
        await store.perform(.checkout(.pro))
        #expect(gateway.calls.isEmpty && store.status == nil)
    }

    @Test func aFailedFirstReadShowsTheQuietLineAndALaterGoodReadReplacesIt() async {
        let gateway = FakePlanGateway([.failure(FakePlanGateway.Failure()), .success(F.pro)])
        let (store, _) = make(gateway)
        await store.refresh()
        #expect(store.loadFailed && store.state.sections.first?.empty == "Something went wrong. Try again in a moment.")
        await store.refresh()
        #expect(!store.loadFailed && store.state.row("renews") != nil)
    }

    @Test func aFailedReadAfterAGoodOneKeepsWhatWasShown() async {
        let gateway = FakePlanGateway([.success(F.pro), .failure(FakePlanGateway.Failure())])
        let (store, _) = make(gateway)
        await store.refresh()
        await store.refresh()
        #expect(!store.loadFailed && store.state.row("renews") != nil)
    }

    @Test func anOlderResponseNeverReplacesANewerOne() async {
        let slow = AsyncGate()
        let gateway = FakePlanGateway([.success(F.pro), .success(F.status(.cancelled, plan: .monthly, cancelAt: "2026-11-08T00:00:00Z"))])
        gateway.gateNextStatus(slow)
        let (store, _) = make(gateway)
        let first = Task { await store.refresh() }
        await waitUntil("첫 읽기가 문 앞에 도착") { slow.entered == 1 }
        await store.refresh()
        #expect(store.status?.state == .cancelled)
        slow.open()
        await first.value
        #expect(store.status?.state == .cancelled, "늦게 온 옛 응답을 버린다")
    }

    // MARK: checkout · 포털 · 다시 시작

    @Test func checkoutSendsTheProductAndTheTermsVersionFromTheStatusThenOpensTheAddressOnce() async {
        let gateway = FakePlanGateway(status: F.none)
        let (store, opened) = make(gateway)
        await store.refresh()
        await store.perform(.checkout(.pro))
        #expect(gateway.calls == ["status", "checkout:pro:terms-2026-test"])
        #expect(opened.urls == [URL(string: "https://acme.lemonsqueezy.com/checkout/buy/test")!])
        #expect(store.busy == nil && store.failure == nil)
        await store.perform(.checkout(.lifetime))
        #expect(gateway.calls.last == "checkout:lifetime:terms-2026-test")
    }

    @Test func aCheckoutFailureOpensNothingAndSaysSoOnTheRow() async {
        let gateway = FakePlanGateway(status: F.none)
        gateway.checkoutResult = .failure(FakePlanGateway.Failure())
        let (store, opened) = make(gateway)
        await store.refresh()
        await store.perform(.checkout(.pro))
        #expect(opened.urls.isEmpty && store.failure == .checkout(.pro))
        #expect(store.state.row("pro")?.detail.contains("Couldn't open checkout. Try again in a moment.") == true)
        await store.perform(.checkout(.lifetime))
        #expect(store.failure == .checkout(.lifetime), "새 시도가 앞 실패를 지운다")
    }

    @Test func checkoutNeedsAStatusSoItNeverGuessesTheTermsVersion() async {
        let gateway = FakePlanGateway(status: F.none)
        let (store, opened) = make(gateway)
        await store.perform(.checkout(.pro))
        #expect(gateway.calls.isEmpty && opened.urls.isEmpty)
    }

    @Test func aSecondTapWhileOneActionIsRunningIsIgnored() async {
        let gate = AsyncGate(holdsOnlyFirst: true)
        let gateway = FakePlanGateway(status: F.none)
        gateway.checkoutGate = gate
        let (store, opened) = make(gateway)
        await store.refresh()
        let first = Task { await store.perform(.checkout(.pro)) }
        await waitUntil("checkout이 서버 앞에 도착") { gate.entered == 1 }
        #expect(store.busy == .checkout(.pro) && store.state.isBusy)
        await store.perform(.checkout(.pro))
        await store.perform(.checkout(.lifetime))
        await store.perform(.askRefund)
        await store.perform(.portal(.manage))
        #expect(gateway.calls.filter { $0.hasPrefix("checkout") }.count == 1 && !gateway.calls.contains { $0.hasPrefix("portal") })
        gate.open()
        await first.value
        #expect(opened.urls.count == 1 && store.busy == nil)
    }

    @Test func thePortalOpensTheManageAndPaymentAddressesThroughTheServer() async {
        let gateway = FakePlanGateway(status: F.pro)
        let (store, opened) = make(gateway)
        await store.refresh()
        await store.perform(.portal(.manage))
        await store.perform(.portal(.payment))
        #expect(gateway.calls == ["status", "portal:manage", "portal:payment"])
        #expect(opened.urls.count == 2)
        gateway.portalResult = .failure(FakePlanGateway.Failure())
        await store.perform(.portal(.manage))
        #expect(store.failure == .portal(.manage) && opened.urls.count == 2)
    }

    @Test func resumeAsksTheServerThenReadsAgainBecauseTheEntitlementChangesByWebhook() async {
        let gateway = FakePlanGateway(status: F.status(.cancelled, plan: .monthly, cancelAt: "2026-11-08T00:00:00Z"))
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.resume)
        #expect(gateway.calls == ["status", "resume", "status"])
        gateway.resumeError = FakePlanGateway.Failure()
        await store.perform(.resume)
        #expect(store.failure == .resume && gateway.calls.last == "resume", "실패하면 다시 읽지 않는다")
    }

    // MARK: checkout 뒤 돌아옴

    @Test func comingBackFromCheckoutReadsAsCheckingThenKeepsReadingUntilTheStateChanges() async {
        let gate = AsyncGate()
        let gateway = FakePlanGateway([.success(F.none), .success(F.none), .success(F.none), .success(F.status(.trial, plan: .monthly, trialEndsAt: "2026-10-23T12:00:00Z"))])
        let pauses = PauseCounter()
        let (store, _) = make(gateway, settleReads: 5, pauses: pauses)
        await store.refresh()
        await store.perform(.checkout(.pro))
        gateway.gateNextStatus(gate)
        let back = Task { await store.appDidBecomeActive() }
        await waitUntil("돌아와서 읽는 중") { gate.entered == 1 }
        #expect(store.settling && store.state.row("plan")?.control == .value("Checking…", bold: false) && store.state.rows.count == 1)
        gate.open()
        await back.value
        #expect(!store.settling && store.status?.state == .trial, "webhook이 닿으면 상태가 바뀐다")
        #expect(gateway.statusCalls == 4 && pauses.count == 2, "처음 읽기 뒤 상태가 안 바뀌어 두 번 더 읽었다")
    }

    @Test func comingBackWithoutBuyingStopsAfterTheLimitedNumberOfReads() async {
        let gateway = FakePlanGateway(status: F.none)
        let pauses = PauseCounter()
        let (store, _) = make(gateway, settleReads: 3, pauses: pauses)
        await store.refresh()
        await store.perform(.checkout(.pro))
        await store.appDidBecomeActive()
        #expect(gateway.statusCalls == 1 + 3 && pauses.count == 2 && !store.settling && store.status?.state == BillingStatusV2.State.none)
        // 한 번 돌아온 것으로 끝: 다시 활성화되면 평범한 한 번 읽기
        await store.appDidBecomeActive()
        #expect(gateway.statusCalls == 1 + 3 + 1)
    }

    @Test func becomingActiveWithoutHavingOpenedCheckoutIsOneSilentRead() async {
        let gateway = FakePlanGateway(status: F.pro)
        let (store, _) = make(gateway)
        await store.refresh()
        await store.appDidBecomeActive()
        #expect(gateway.statusCalls == 2 && !store.settling)
    }

    // MARK: 환불

    @Test func askingAndCancellingTheRefundNeverTouchesTheServer() async {
        let gateway = FakePlanGateway(status: F.pro)
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.askRefund)
        #expect(store.askingRefund && gateway.calls == ["status"])
        await store.perform(.cancelRefund)
        #expect(!store.askingRefund && gateway.calls == ["status"])
    }

    @Test func confirmingTheRefundSendsOneRequestThenShowsTheServersRequestedNoticeWhileThePlanStaysUntilConfirmed() async {
        let requested = F.status(.pro, plan: .monthly, periodEndsAt: "2026-11-08T00:00:00Z", refundState: .requested, tokens: 2_400_000)
        let gateway = FakePlanGateway([.success(F.pro), .success(requested)])
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.askRefund)
        await store.perform(.confirmRefund)
        #expect(gateway.calls == ["status", "refund", "status"])
        #expect(!store.askingRefund && !store.refundRequested, "서버가 requested를 알려 주면 서버가 진실이다: 이 화면의 표시는 쓰지 않는다")
        let state = store.state
        #expect(state.notice?.title == "Refund requested" && state.row("plan")?.control == .value("Pro · Monthly · $12.99 a month", bold: false), "자격은 확정 뒤에만 바뀐다")
        #expect(state.row("refund") == nil)
    }

    @Test func whenALaterReadSaysThePlanEndedTheNoticeBecomesRefundIssued() async {
        let gateway = FakePlanGateway([.success(F.pro), .success(F.pro), .success(F.status(.lapsed, canCheckout: true, canBuyLifetime: true))])
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.confirmRefund)
        #expect(store.refundIssued == nil)
        await store.refresh()
        #expect(store.refundIssued == .pro && !store.refundRequested)
        let state = store.state
        #expect(state.notice?.title == "Refund issued" && state.rows.map(\.id) == ["plan"] && state.row("plan")?.control == .value("No plan", bold: false))
    }

    @Test func aLifetimeRefundIssuedSaysLifetimeEnds() async {
        let gateway = FakePlanGateway([.success(F.lifetime), .success(F.lifetime), .success(F.status(.none, canCheckout: true))])
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.confirmRefund)
        await store.refresh()
        #expect(store.refundIssued == .lifetime && store.state.notice?.message == "Lifetime ends now. Your lists, results and sources stay available.")
    }

    @Test func aRefundTheServerRefusedClosesTheConfirmationReadsAgainAndSaysSoOnTheRow() async {
        let gateway = FakePlanGateway(status: F.pro)
        gateway.refundError = APIError.server(status: 409, code: .billingRefundWindowClosed, message: "x")
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.askRefund)
        await store.perform(.confirmRefund)
        #expect(!store.askingRefund && !store.refundRequested && store.failure == .refund && gateway.calls == ["status", "refund", "status"])
        #expect(store.state.row("refund")?.detail.last == "Something went wrong. Try again in a moment.")
    }

    // MARK: 계정이 떠난 뒤의 늦은 응답 (PR-C 검토 1 P1): follow를 부르지 않아도 URL을 열기 직전에 현재 계정을 본다

    @Test func aLateCheckoutAnswerOpensNothingWhenTheAccountLeftEvenWithoutAFollowCall() async {
        for next in [nil, other] as [UUID?] {
            let gate = AsyncGate(holdsOnlyFirst: true)
            let gateway = FakePlanGateway(status: F.none)
            gateway.checkoutGate = gate
            let account = AccountBox(user)
            let (store, opened) = make(gateway, account: account)
            await store.refresh()
            let late = Task { await store.perform(.checkout(.pro)) }
            await waitUntil("checkout이 서버 앞에 도착") { gate.entered == 1 }
            account.id = next
            gate.open()
            await late.value
            #expect(opened.urls.isEmpty, "계정이 떠난 뒤 \(String(describing: next)): 전 계정의 결제 주소를 열지 않는다")
            #expect(store.owner == nil && store.status == nil && store.busy == nil, "저장소가 무효화됐다")
        }
    }

    @Test func aLateCheckoutAnswerOpensNothingAfterTheStoreWasInvalidatedByLeavingTheScreen() async {
        let gate = AsyncGate(holdsOnlyFirst: true)
        let gateway = FakePlanGateway(status: F.none)
        gateway.checkoutGate = gate
        let (store, opened) = make(gateway, account: AccountBox(user))
        await store.refresh()
        let late = Task { await store.perform(.checkout(.lifetime)) }
        await waitUntil("checkout이 서버 앞에 도착") { gate.entered == 1 }
        store.follow(userID: nil, gateway: nil)
        gate.open()
        await late.value
        #expect(opened.urls.isEmpty && store.owner == nil)
    }

    @Test func aLatePortalAnswerOpensNothingWhenTheAccountLeft() async {
        let gate = AsyncGate(holdsOnlyFirst: true)
        let gateway = FakePlanGateway(status: F.pro)
        gateway.portalGate = gate
        let account = AccountBox(user)
        let (store, opened) = make(gateway, account: account)
        await store.refresh()
        let late = Task { await store.perform(.portal(.payment)) }
        await waitUntil("포털이 서버 앞에 도착") { gate.entered == 1 }
        account.id = nil
        gate.open()
        await late.value
        #expect(opened.urls.isEmpty && store.owner == nil && store.busy == nil)
    }

    @Test func aLateStatusReadForAnAccountThatLeftIsDropped() async {
        let gate = AsyncGate(holdsOnlyFirst: true)
        let gateway = FakePlanGateway(status: F.pro)
        gateway.gateNextStatus(gate)
        let account = AccountBox(user)
        let (store, _) = make(gateway, account: account)
        let late = Task { await store.refresh() }
        await waitUntil("읽기가 서버 앞에 도착") { gate.entered == 1 }
        account.id = other
        gate.open()
        await late.value
        #expect(store.status == nil && store.owner == nil)
    }

    @Test func aKeyAnswerForAnAccountThatLeftChangesNothing() async {
        let account = AccountBox(user)
        let (store, _) = make(FakePlanGateway(status: F.status(.lifetime, aiKey: .missing)), account: account)
        await store.refresh()
        account.id = nil
        await store.saveKey(SecretBox("sk-or-v1-aaaabbbbccccdddd"))
        #expect(store.status == nil && store.owner == nil, "계정이 떠난 뒤의 응답은 아무 화면도 바꾸지 않는다")
    }

    @Test func theOpenerStillWorksWhileTheOwnerIsTheCurrentAccount() async {
        let gateway = FakePlanGateway(status: F.none)
        let (store, opened) = make(gateway, account: AccountBox(user))
        await store.refresh()
        await store.perform(.checkout(.pro))
        #expect(opened.urls.count == 1 && store.owner == user)
    }

    // MARK: 환불 안내는 서버 상태를 따른다 (PR-C 검토 1 P2)

    @Test func theRequestedNoticeFollowsTheServerSoAnIdleReadClearsIt() async {
        let requested = F.status(.pro, plan: .monthly, periodEndsAt: "2026-11-08T00:00:00Z", refundUntil: "2026-10-23T12:00:00Z", refundState: .requested, tokens: 2_400_000)
        let gateway = FakePlanGateway([.success(F.pro), .success(requested)])
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.confirmRefund)
        #expect(store.state.notice?.title == "Refund requested")
        // 서버가 미확정 요청을 정리하고 idle로 돌려줬다: 안내가 사라지고 환불 줄이 다시 선다
        gateway.setStatuses([.success(F.pro)])
        await store.refresh()
        #expect(store.state.notice == nil && store.state.row("refund") != nil && !store.refundRequested)
    }

    @Test func theLocalRequestMarkOnlyBridgesUntilTheNextGoodRead() async {
        let gateway = FakePlanGateway([.success(F.pro), .failure(FakePlanGateway.Failure())])
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.confirmRefund)
        #expect(store.refundRequested && store.state.notice?.title == "Refund requested", "되읽기가 실패해도 요청을 보냈다는 사실은 보인다")
        gateway.setStatuses([.success(F.pro)])
        await store.refresh()
        #expect(!store.refundRequested && store.state.notice == nil, "서버의 다음 상태가 이긴다")
    }

    @Test func aRequestedNoticeThatTheServerKeepsSurvivesReenteringTheScreen() async {
        let requested = F.status(.pro, plan: .monthly, periodEndsAt: "2026-11-08T00:00:00Z", refundState: .requested)
        let (store, _) = make(FakePlanGateway(status: requested))
        await store.refresh()
        store.beginVisit()
        #expect(store.state.notice?.title == "Refund requested", "서버가 아는 요청은 화면에 다시 들어와도 그대로다")
    }

    @Test func aRefundIssuedNoticeBelongsToItsOwnVisitAndTheSameAccountSeesThePurchaseRowsWhenItComesBack() async {
        let gateway = FakePlanGateway([.success(F.pro), .success(F.status(.none, canCheckout: true, canBuyLifetime: true, withTrial: false))])
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.confirmRefund)
        #expect(store.state.notice?.title == "Refund issued" && store.state.rows.map(\.id) == ["plan"], "그 확인 흐름 안에서는 보인다")
        // 같은 계정이 화면에 다시 들어왔다 (탭을 옮겼다 돌아옴 · 창을 다시 엶)
        store.beginVisit()
        let state = store.state
        #expect(store.refundIssued == nil && state.notice == nil)
        #expect(state.rows.map(\.id) == ["plan", "pro", "lifetime"], "서버가 허용한 구매 줄이 다시 보인다")
    }

    @Test func aRefundThatEndsAfterTheVisitWasLeftIsNotCalledIssued() async {
        let requested = F.status(.pro, plan: .monthly, periodEndsAt: "2026-11-08T00:00:00Z", refundState: .requested)
        let gateway = FakePlanGateway([.success(F.pro), .success(requested)])
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.confirmRefund)
        store.beginVisit()
        gateway.setStatuses([.success(F.status(.lapsed, canCheckout: true, canBuyLifetime: true))])
        await store.refresh()
        #expect(store.refundIssued == nil && store.state.notice?.title == "Pro ended · AI and execution paused")
    }

    @Test func reenteringClearsAnOpenRefundConfirmationToo() async {
        let (store, _) = make(FakePlanGateway(status: F.pro))
        await store.refresh()
        await store.perform(.askRefund)
        store.beginVisit()
        #expect(!store.askingRefund)
    }

    // MARK: 키

    @Test func savingAKeySendsItOnceAndTheRowsBecomeConnected() async {
        let gateway = FakePlanGateway(status: F.status(.lifetime, aiKey: .missing))
        let (store, _) = make(gateway)
        await store.refresh()
        gateway.setStatuses([.success(F.status(.lifetime, aiKey: .connected))])
        await store.saveKey(SecretBox("sk-or-v1-aaaabbbbccccdddd"))
        #expect(gateway.savedKeys == ["sk-or-v1-aaaabbbbccccdddd"] && gateway.calls == ["status", "saveKey", "status"])
        #expect(store.state.row("key")?.control == .value("Connected", bold: false) && store.state.row("key-entry")?.label == "Replace key")
        #expect(store.busy == nil && store.failure == nil)
    }

    @Test func theRowsAreRightEvenIfTheReadAfterSavingFails() async {
        let gateway = FakePlanGateway([.success(F.status(.lifetime, aiKey: .missing)), .failure(FakePlanGateway.Failure())])
        let (store, _) = make(gateway)
        await store.refresh()
        await store.saveKey(SecretBox("sk-or-v1-aaaabbbbccccdddd"))
        #expect(store.state.row("key")?.control == .value("Connected", bold: false))
    }

    @Test(arguments: [
        (APIError.server(status: 422, code: .aiKeyInvalid, message: "x"), PlanSummaryInput.KeyFailure.invalid),
        (APIError.server(status: 422, code: .aiKeyManagement, message: "x"), .management),
        (APIError.server(status: 429, code: .rateLimited, message: "x"), .generic),
        (APIError.server(status: 503, code: .billingUnavailable, message: "x"), .generic),
        (APIError.server(status: 404, code: .notFound, message: "x"), .generic),
        (APIError.transport("offline"), .generic),
    ])
    func keyFailuresMapToTheThreeQuietLines(_ error: APIError, _ expected: PlanSummaryInput.KeyFailure) async {
        let gateway = FakePlanGateway(status: F.status(.lifetime, aiKey: .missing))
        gateway.saveError = error
        let (store, _) = make(gateway)
        await store.refresh()
        await store.saveKey(SecretBox("sk-or-v1-aaaabbbbccccdddd"))
        #expect(store.failure == .keySave(expected) && gateway.calls == ["status", "saveKey"], "실패하면 다시 읽지 않고 Missing 그대로")
        #expect(store.state.row("key")?.control == .value("Missing", bold: true))
    }

    @Test func aKeyIsOnlySentFromALifetimeAccountAndNeverEmpty() async {
        let gateway = FakePlanGateway(status: F.pro)
        let (store, _) = make(gateway)
        await store.refresh()
        await store.saveKey(SecretBox("sk-or-v1-aaaabbbbccccdddd"))
        #expect(gateway.savedKeys.isEmpty, "Pro 계정은 키 칸이 없다")
        let lifetime = FakePlanGateway(status: F.lifetime)
        let (store2, _) = make(lifetime)
        await store2.refresh()
        await store2.saveKey(SecretBox(""))
        #expect(lifetime.savedKeys.isEmpty)
    }

    @Test func theKeyNeverStaysInTheStoreOrAnyTextItProduces() async {
        let secret = "sk-or-v1-NEVER-SHOW-THIS-0123456789"
        let gateway = FakePlanGateway(status: F.status(.lifetime, aiKey: .missing))
        gateway.saveError = APIError.server(status: 422, code: .aiKeyInvalid, message: "서버 설명")
        gateway.recordsKeys = false
        let (store, _) = make(gateway)
        await store.refresh()
        await store.saveKey(SecretBox(secret))
        // 저장소의 모든 저장 속성(비공개 · 관찰 제외 포함)을 거울로 훑은 글에도 키가 없다
        var walked = ""
        dump(store, to: &walked, maxDepth: 6)
        let dumps = [String(describing: store), String(reflecting: store), String(describing: store.state), store.state.allText.joined(separator: "\n"), String(describing: store.failure as Any), walked]
        for dump in dumps { #expect(!dump.contains(secret) && !dump.contains("NEVER-SHOW")) }
        #expect(Mirror(reflecting: SecretBox(secret)).children.isEmpty && "\(SecretBox(secret))" == "<secret>")
    }

    @Test func removingAKeyAsksFirstThenDeletesAndShowsMissing() async {
        let gateway = FakePlanGateway(status: F.lifetime)
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.askRemoveKey)
        #expect(store.confirmingRemoveKey && gateway.calls == ["status"])
        await store.perform(.cancelRemoveKey)
        #expect(!store.confirmingRemoveKey)
        gateway.setStatuses([.success(F.status(.lifetime, aiKey: .missing))])
        await store.perform(.askRemoveKey)
        await store.perform(.confirmRemoveKey)
        #expect(gateway.calls == ["status", "removeKey", "status"] && !store.confirmingRemoveKey)
        #expect(store.state.row("key")?.control == .value("Missing", bold: true) && store.state.row("key-remove") == nil)
    }

    @Test func aFailedRemoveClosesTheConfirmationAndSaysSoOnTheRow() async {
        let gateway = FakePlanGateway(status: F.lifetime)
        gateway.removeError = FakePlanGateway.Failure()
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.askRemoveKey)
        await store.perform(.confirmRemoveKey)
        #expect(!store.confirmingRemoveKey && store.failure == .keyRemove && store.state.row("key")?.control == .value("Connected", bold: false))
        #expect(store.state.row("key-remove")?.detail == ["Something went wrong. Try again in a moment."])
    }

    // MARK: 계정

    @Test func aLateReadForAnotherAccountIsDiscarded() async {
        let gate = AsyncGate()
        let gateway = FakePlanGateway(status: F.pro)
        gateway.gateNextStatus(gate)
        let (store, _) = make(gateway)
        let late = Task { await store.refresh() }
        await waitUntil("읽기가 문 앞에 도착") { gate.entered == 1 }
        store.follow(userID: other, gateway: gateway)
        #expect(store.status == nil && store.owner == other)
        gate.open()
        await late.value
        #expect(store.status == nil, "전 계정의 늦은 응답은 새 계정 화면에 쓰지 않는다")
    }

    @Test func aLateCheckoutAnswerAfterAnAccountSwitchOpensNothingAndClearsNothingForTheNewAccount() async {
        let gate = AsyncGate(holdsOnlyFirst: true)
        let gateway = FakePlanGateway(status: F.none)
        gateway.checkoutGate = gate
        let (store, opened) = make(gateway)
        await store.refresh()
        let late = Task { await store.perform(.checkout(.pro)) }
        await waitUntil("checkout이 서버 앞에 도착") { gate.entered == 1 }
        store.follow(userID: other, gateway: gateway)
        #expect(store.busy == nil, "새 계정은 눌림 없이 시작한다")
        gate.open()
        await late.value
        #expect(opened.urls.isEmpty && store.busy == nil && store.failure == nil)
    }

    @Test func signingOutClearsEverythingAndStopsAllCalls() async {
        let gateway = FakePlanGateway(status: F.lifetime)
        let (store, _) = make(gateway)
        await store.refresh()
        await store.perform(.askRefund)
        store.follow(userID: nil, gateway: gateway)
        #expect(store.status == nil && !store.askingRefund && store.owner == nil)
        await store.refresh()
        await store.saveKey(SecretBox("sk-or-v1-aaaabbbbccccdddd"))
        #expect(gateway.calls == ["status"] && gateway.savedKeys.isEmpty)
    }

    @Test func followingTheSameAccountAgainKeepsWhatIsShown() async {
        let gateway = FakePlanGateway(status: F.pro)
        let (store, _) = make(gateway)
        await store.refresh()
        store.follow(userID: user, gateway: gateway)
        #expect(store.status != nil)
    }
}

/// 몇 번 쉬었나 (조용한 다시 읽기 사이의 쉼, 실제로는 자지 않는다)
final class PauseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks = 0
    var count: Int { lock.withLock { ticks } }
    func tick() { lock.withLock { ticks += 1 } }
}
