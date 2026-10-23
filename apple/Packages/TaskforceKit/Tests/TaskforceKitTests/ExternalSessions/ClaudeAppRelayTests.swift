#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 데스크톱 세션으로 글을 넣는 중계 관리자 (PR-D3k, 계약 25.4.1 · 위협 DT4 · DT5 · DT6 · DT7 · DT12 · DT13): 지킴이 아래 `claude -p` stream-json + 번들 mod `tf-relay`.
    /// 인자는 바이트까지 고정이고, 글은 **stdin으로만** 간다. 띄우기 전 mod 해시, 띄운 뒤 `/tfping` nonce, 결과마다 모델 0 확인(어기면 중계를 끝내고 이 실행 동안 S2를 끈다), 쓰는 사람이 없으면 2분 뒤 끝낸다.
    /// 실제 `claude`는 부르지 않는다 (가짜 프로세스 · 가짜 launcher · 손으로 흘리는 시계)
    struct ClaudeAppRelayTests {
        typealias L = RelayLines
        let target = "5e5e5e5e-0000-4000-8000-0000000000e1"
        let secret = "SENTINEL-USER-MESSAGE-TEXT-한글-😀"
        let work = "/private/tmp/tf-relay-work-folder"

        private struct Rig {
            let relay: ClaudeAppRelay
            let launcher: FakeRelayLauncher
            let sleeper: ClaudeAppManualSleeper
            let log: RelayLog
            let mod: String
            var pidsEmpty: Bool { relay.pids.current.isEmpty }
        }

        private func makeRig(
            _ launcher: FakeRelayLauncher = FakeRelayLauncher(), mod: String? = nil, nonce: String = "0123456789abcdef0123456789abcdef", commandTimeout: TimeInterval = 20
        ) throws -> Rig {
            let sleeper = ClaudeAppManualSleeper()
            let log = RelayLog()
            let mod = try mod ?? ClaudeAppModFixture.copy()
            let relay = ClaudeAppRelay(
                configuration: ClaudeAppRelay.Configuration(modDirectory: mod, workDirectory: work, commandTimeout: commandTimeout), launcher: launcher, makeNonce: { nonce },
                sleep: { await sleeper.sleep($0) }, log: log
            )
            return Rig(relay: relay, launcher: launcher, sleeper: sleeper, log: log, mod: mod)
        }

        // MARK: 인자 (바이트 고정)

        @Test func theArgumentsAreByteFixedWithTheBundledModAndNoBypassOrAutoOrDontAsk() {
            let mod = "/Applications/Taskforce.app/Contents/Resources/tf-relay"
            #expect(
                ClaudeAppRelay.arguments(modDirectory: mod) == [
                    "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--plugin-dir", mod, "--setting-sources", "", "--strict-mcp-config", "--tools", "SendMessage",
                    "--permission-mode", "default", "--name", "Taskforce", "--max-budget-usd", "0.01", "--no-session-persistence",
                ]
            )
            let joined = ClaudeAppRelay.arguments(modDirectory: mod).joined(separator: " ")
            for forbidden in ["bypass", "acceptEdits", "dontAsk", "auto", "dangerously", "--resume", "--continue", "--allow", "--mcp-config ", "--add-dir"] {
                #expect(!joined.contains(forbidden), "\(forbidden)")
            }
        }

        // MARK: 보내기 길 (stdin만)

        @Test func theFirstCommandIsThePingAndTheTextGoesOnlyThroughStdin() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            let result = await rig.relay.send(sessionID: target, text: secret)
            #expect(result == .delivered(relayPID: 4001))
            let process = try #require(rig.launcher.processes.first)
            #expect(process.contents == ["/tfping 0123456789abcdef0123456789abcdef", "/tfsend \(target)\n\(secret)"], "첫 명령은 /tfping, 글은 /tfsend 다음 줄")
            // DT6: argv · 로그에 글이 없다
            let launch = try #require(rig.launcher.launches.first)
            #expect(launch.arguments == ClaudeAppRelay.arguments(modDirectory: rig.mod) && launch.cwd == work)
            let argumentText: String = launch.arguments.joined(separator: " ")
            #expect(!argumentText.contains("SENTINEL") && !launch.cwd.contains("SENTINEL"))
            let logText = rig.log.text
            #expect(!logText.contains("SENTINEL") && !logText.contains(target), "로그는 고정 코드뿐: \(logText)")
            // 글은 stdin 줄 하나에 JSON 글자열로 들어간다 (줄바꿈은 이스케이프)
            let line = try #require(process.writes.last)
            #expect(line.contains("SENTINEL-USER-MESSAGE-TEXT") && !line.dropLast().contains("\n"))
        }

        @Test func prepareStartsAndHealthChecksTheRelayWithoutSendingAnythingSoTheFirstSendIsFast() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            await rig.relay.retain()
            #expect(await rig.relay.prepare())
            #expect(rig.launcher.processes[0].contents == ["/tfping 0123456789abcdef0123456789abcdef"], "핑뿐: 글은 없다")
            #expect(await rig.relay.readiness() == .ready)
            #expect(await rig.relay.send(sessionID: target, text: "hello") == .delivered(relayPID: 4001))
            #expect(rig.launcher.launches.count == 1, "미리 띄운 중계를 쓴다")
            // 모델 턴이 나오면 준비도 실패한다
            let off = try makeRig(FakeRelayLauncher(make: { FakeRelayProcess(pid: Int32(4000 + $0), rule: { _, _ in L.modelTurn }) }))
            defer { ClaudeAppModFixture.cleanup(off.mod) }
            #expect(await off.relay.prepare() == false)
            #expect(await off.relay.readiness() == .unavailable)
        }

        @Test func theRelayIsStartedOnceAndTheNextSendReusesIt() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            _ = await rig.relay.send(sessionID: target, text: "one")
            _ = await rig.relay.send(sessionID: target, text: "two")
            #expect(rig.launcher.launches.count == 1)
            #expect(rig.launcher.processes[0].contents == ["/tfping 0123456789abcdef0123456789abcdef", "/tfsend \(target)\none", "/tfsend \(target)\ntwo"])
            #expect(await rig.relay.readiness() == .ready)
        }

        @Test func everyOutcomeOfTheModIsMappedToDeliveredOrAReason() async throws {
            let closed = "no live session on this machine has id \(target) (a session that exited)"
            let cases: [(String, [Data], ClaudeAppRelaySendResult)] = [
                ("전달", L.sent(delivered: true), .delivered(relayPID: 4001)),
                ("닫힘", L.sent(delivered: false, reason: closed), .notDelivered(.sessionClosed)),
                ("받지 않음", L.sent(delivered: false, reason: "this session has no SendMessage tool"), .notDelivered(.notReceived)),
                ("mod 거절", L.modAnswer(["mod": "tf-relay", "version": "1", "ok": false, "error": "bad_args"]), .notDelivered(.relayFailed)),
            ]
            for (name, answer, expected) in cases {
                let rig = try makeRig()
                defer { ClaudeAppModFixture.cleanup(rig.mod) }
                let process = FakeRelayProcess(pid: 4001) { content, nonce in content.hasPrefix("/tfping ") ? L.ping(nonce: nonce ?? "") : answer }
                rig.launcher.enqueue(process)
                #expect(await rig.relay.send(sessionID: target, text: "hello") == expected, "\(name)")
            }
        }

        @Test func inputsTheModWouldRefuseNeverReachTheProcess() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            let bad: [(String, String, String)] = [
                ("대문자 UUID", target.uppercased(), "hello"), ("UUID 아님", "not-a-uuid", "hello"), ("옵션 모양", "--resume", "hello"), ("빈 글", target, ""),
                ("16,001자", target, String(repeating: "x", count: 16_001)), ("NUL", target, "a\u{0}b"),
            ]
            for (name, id, text) in bad {
                #expect(await rig.relay.send(sessionID: id, text: text) == .notDelivered(.relayFailed), "\(name)")
            }
            #expect(rig.launcher.launches.isEmpty, "검사에서 걸러 중계를 띄우지도 않는다")
            let longest = String(repeating: "x", count: 16_000)
            #expect(await rig.relay.send(sessionID: target, text: longest) == .delivered(relayPID: 4001), "16,000자는 간다")
        }

        // MARK: 건강 확인 (DT12)

        @Test func aPingThatComesBackWithAnotherNonceOrAnotherShapeStopsTheRelayAndNothingIsSent() async throws {
            let answers: [(String, @Sendable (String, String?) -> [Data]?)] = [
                ("다른 nonce", { _, _ in L.ping(nonce: "ffffffffffffffffffffffffffffffff") }),
                ("mod가 없는 답", { _, _ in L.modAnswer(["mod": "other", "version": "1", "ok": true, "nonce": "0123456789abcdef0123456789abcdef"]) }),
            ]
            for (name, rule) in answers {
                let rig = try makeRig(FakeRelayLauncher(make: { FakeRelayProcess(pid: Int32(4000 + $0), rule: rule) }))
                defer { ClaudeAppModFixture.cleanup(rig.mod) }
                #expect(await rig.relay.send(sessionID: target, text: secret) == .notDelivered(.relayFailed), "\(name)")
                let process = try #require(rig.launcher.processes.first)
                #expect(process.isStopped && process.contents.count == 1 && !process.contents.contains { $0.contains("SENTINEL") }, "\(name): 글은 쓰지 않았다")
                #expect(await rig.relay.readiness() == .notRunning, "\(name): 한 번 실패해도 이 실행을 끄지는 않는다")
            }
        }

        @Test func aModelTurnAnswerToThePingKillsTheRelayAndTurnsTheFeatureOffForThisRun() async throws {
            // DT12: mod가 안 올라와 /tfping이 모델에 갔다 → 보내기 0 · S2 꺼짐
            let rig = try makeRig(FakeRelayLauncher(make: { FakeRelayProcess(pid: Int32(4000 + $0), rule: { _, _ in L.modelTurn }) }))
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            #expect(await rig.relay.send(sessionID: target, text: secret) == .notDelivered(.relayFailed))
            #expect(rig.launcher.processes[0].isStopped && rig.launcher.processes[0].contents.count == 1 && !rig.launcher.processes[0].contents.joined().contains("SENTINEL"))
            #expect(await rig.relay.readiness() == .unavailable)
            #expect(rig.log.events("claude_app_relay").contains { $0["result"] == .code("model_turn") })
            // 이후 보내기는 띄우지도 않는다
            #expect(await rig.relay.send(sessionID: target, text: "again") == .notDelivered(.relayFailed))
            #expect(rig.launcher.launches.count == 1)
        }

        @Test func aModelTurnInTheAnswerToASendOrOutOfNowhereAlsoTurnsItOff() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            let process = FakeRelayProcess(pid: 4001) { content, nonce in content.hasPrefix("/tfping ") ? L.ping(nonce: nonce ?? "") : L.modelTurn }
            rig.launcher.enqueue(process)
            #expect(await rig.relay.send(sessionID: target, text: "hello") == .notDelivered(.relayFailed))
            let readiness = await rig.relay.readiness()
            #expect(process.isStopped && readiness == .unavailable)

            let quiet = try self.makeRig()
            defer { ClaudeAppModFixture.cleanup(quiet.mod) }
            _ = await quiet.relay.send(sessionID: target, text: "first")
            let alive = quiet.launcher.processes[0]
            alive.emit(L.modelTurn)
            #expect(await relayEventually { alive.isStopped }, "끼어든 모델 턴 줄도 끝낸다")
            #expect(await quiet.relay.readiness() == .unavailable)
        }

        @Test func aResultThatIsNotAModAnswerButHasNoModelTurnLinesStillCountsAsAModelTurn() async throws {
            // result만 어긋나도(비용 0.002) 모델을 불렀다
            let costly = L.modAnswer(["mod": "tf-relay", "version": "1", "ok": true, "isDelivered": true, "reason": NSNull()]).map { line -> Data in
                guard var object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["type"] as? String == "result" else { return line }
                object["total_cost_usd"] = 0.002
                return L.json(object)
            }
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            rig.launcher.enqueue(FakeRelayProcess(pid: 4001) { content, nonce in content.hasPrefix("/tfping ") ? L.ping(nonce: nonce ?? "") : costly })
            #expect(await rig.relay.send(sessionID: target, text: "hello") == .notDelivered(.relayFailed))
            #expect(await rig.relay.readiness() == .unavailable)
        }

        // MARK: mod 해시 (DT7)

        @Test func aModWithAChangedFileIsNeverSpawned() async throws {
            let mod = try ClaudeAppModFixture.copy()
            defer { ClaudeAppModFixture.cleanup(mod) }
            try Data("export function register() {}\n".utf8).write(to: URL(fileURLWithPath: mod + "/hooks/register.js"))
            let rig = try makeRig(mod: mod)
            #expect(await rig.relay.send(sessionID: target, text: secret) == .notDelivered(.relayFailed))
            #expect(rig.launcher.launches.isEmpty, "해시 다른 mod → 중계 띄우기 0")
            #expect(rig.log.events("claude_app_relay").contains { $0["result"] == .code("mod_hash") })
            #expect(!rig.log.text.contains("hooks/register.js"), "파일 이름도 로그에 안 남긴다: 코드뿐")
            // 고쳐 놓으면 다음 보내기에서 띄운다 (이 실행을 끄지 않는다)
            try FileManager.default.removeItem(atPath: mod)
            let good = try ClaudeAppModFixture.copy()
            defer { ClaudeAppModFixture.cleanup(good) }
            let again = try self.makeRig(mod: good)
            #expect(await again.relay.send(sessionID: target, text: "ok") == .delivered(relayPID: 4001))
        }

        // MARK: 띄우기 실패 · 시간 초과 · 죽음

        @Test func aLaunchFailureIsNotDeliveredAndTheNextSendTriesAgain() async throws {
            let launcher = FakeRelayLauncher()
            launcher.failNext()
            let rig = try makeRig(launcher)
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            #expect(await rig.relay.send(sessionID: target, text: "one") == .notDelivered(.relayFailed))
            #expect(await rig.relay.send(sessionID: target, text: "two") == .delivered(relayPID: 4002))
            #expect(rig.log.events("claude_app_relay").contains { $0["result"] == .code("launch_failed") })
        }

        @Test func aRelayThatNeverAnswersIsStoppedWhenTheCommandTimeoutPasses() async throws {
            let rig = try makeRig(FakeRelayLauncher(make: { FakeRelayProcess(pid: Int32(4000 + $0), rule: { _, _ in nil }) }))
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            let send = Task { await rig.relay.send(sessionID: target, text: "hello") }
            #expect(await relayEventually { rig.sleeper.pending >= 1 })
            #expect(rig.sleeper.requested.contains(30), "첫 명령(핑)은 시작 시간 안에서 기다린다")
            rig.sleeper.advance(30)
            #expect(await send.value == .notDelivered(.relayFailed))
            #expect(rig.launcher.processes[0].isStopped)
            #expect(rig.log.events("claude_app_relay").contains { $0["result"] == .code("timeout") })
        }

        @Test func aSendThatTimesOutAfterAHealthyStartStopsTheRelayToo() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            let process = FakeRelayProcess(pid: 4001) { content, nonce in content.hasPrefix("/tfping ") ? L.ping(nonce: nonce ?? "") : nil }
            rig.launcher.enqueue(process)
            let send = Task { await rig.relay.send(sessionID: target, text: "hello") }
            #expect(await relayEventually { rig.sleeper.requested.contains(20) && rig.sleeper.pending >= 1 }, "보내기는 명령 시간(20초) 안에서 기다린다")
            rig.sleeper.advance(20)
            #expect(await send.value == .notDelivered(.relayFailed) && process.isStopped)
        }

        @Test func aRelayThatDiesBetweenSendsIsStartedAgainWithANewPid() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            #expect(await rig.relay.send(sessionID: target, text: "one") == .delivered(relayPID: 4001))
            rig.launcher.processes[0].die()
            #expect(await relayEventually { rig.pidsEmpty }, "끝난 프로세스의 pid는 곧 비운다")
            #expect(await rig.relay.send(sessionID: target, text: "two") == .delivered(relayPID: 4002), "pid가 바뀌었으므로 앞의 글의 pid는 새 중계가 아니다")
            #expect(rig.launcher.launches.count == 2)
        }

        @Test func aRelayWhoseIdentityChangedAfterLaunchIsReplacedBeforeTheWrite() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            _ = await rig.relay.send(sessionID: target, text: "one")
            rig.launcher.processes[0].identityOK = false
            #expect(await rig.relay.readiness() == .mismatch, "⑤ pid · 시작 시각이 띄운 값과 다르다")
            #expect(await rig.relay.send(sessionID: target, text: "two") == .delivered(relayPID: 4002))
            #expect(rig.launcher.processes[0].isStopped)
            #expect(!rig.launcher.processes[0].contents.contains { $0.contains("two") }, "정체가 바뀐 프로세스에는 쓰지 않는다")
        }

        @Test func aStdinWriteThatFailsMeansTheRelayIsDeadAndNothingIsDelivered() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            _ = await rig.relay.send(sessionID: target, text: "one")
            rig.launcher.processes[0].failWrites = true
            #expect(await rig.relay.send(sessionID: target, text: "two") == .notDelivered(.relayFailed))
            #expect(rig.launcher.processes[0].isStopped)
        }

        // MARK: 한 번에 하나 · 순서

        @Test func twoSendsAtOnceAreRunOneAfterTheOtherInOrder() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            async let first = rig.relay.send(sessionID: target, text: "first")
            async let second = rig.relay.send(sessionID: "5e5e5e5e-0000-4000-8000-0000000000e2", text: "second")
            let results = await [first, second]
            #expect(results == [.delivered(relayPID: 4001), .delivered(relayPID: 4001)])
            let contents = rig.launcher.processes[0].contents
            #expect(contents.count == 3 && contents[0].hasPrefix("/tfping "))
            #expect(Set(contents.dropFirst()) == ["/tfsend \(target)\nfirst", "/tfsend 5e5e5e5e-0000-4000-8000-0000000000e2\nsecond"])
            #expect(rig.launcher.launches.count == 1)
        }

        // MARK: 끝냄 (2분 · 즉시)

        @Test func theRelayStopsTwoMinutesAfterTheLastInterestIsReleasedAndNotBefore() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            await rig.relay.retain()
            _ = await rig.relay.send(sessionID: target, text: "one")
            await rig.relay.release()
            #expect(await relayEventually { rig.sleeper.requested.contains(120) })
            rig.sleeper.advance(119)
            try await Task.sleep(for: .milliseconds(30))
            #expect(!rig.launcher.processes[0].isStopped, "119초: 아직")
            rig.sleeper.advance(1)
            #expect(await relayEventually { rig.launcher.processes[0].isStopped }, "120초")
            #expect(await rig.relay.readiness() == .notRunning)
            #expect(await relayEventually { rig.pidsEmpty })
        }

        @Test func interestComingBackBeforeTheTwoMinutesCancelsTheStop() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            await rig.relay.retain()
            _ = await rig.relay.send(sessionID: target, text: "one")
            await rig.relay.release()
            #expect(await relayEventually { rig.sleeper.pending >= 1 })
            await rig.relay.retain()
            rig.sleeper.advance(500)
            try await Task.sleep(for: .milliseconds(30))
            #expect(!rig.launcher.processes[0].isStopped, "다시 쓰는 사람이 생겼다")
            await rig.relay.release()
            await rig.relay.release()
        }

        @Test func aSendWithNobodyHoldingInterestStillStopsTwoMinutesAfterTheSend() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            _ = await rig.relay.send(sessionID: target, text: "one")
            #expect(await relayEventually { rig.sleeper.requested.contains(120) })
            rig.sleeper.advance(120)
            #expect(await relayEventually { rig.launcher.processes[0].isStopped })
        }

        @Test func shutdownStopsTheRelayAtOnceAndASendAfterwardsStartsANewOne() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            await rig.relay.retain()
            _ = await rig.relay.send(sessionID: target, text: "one")
            await rig.relay.shutdown()
            #expect(rig.launcher.processes[0].isStopped && rig.pidsEmpty)
            #expect(await rig.relay.readiness() == .notRunning)
            #expect(await rig.relay.send(sessionID: target, text: "two") == .delivered(relayPID: 4002))
        }

        // MARK: 쓰기 직전의 확인 (OA PR-D3 검토 P2-2) · 종료는 끝 (P3-9) · 일하는 중에는 유휴로 끝내지 않는다 (P3-9)

        @Test func theWriteWaitsForTheRecheckAfterTheRelayIsReadyAndAFailedRecheckSendsNothing() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            let launcher = rig.launcher
            let seen = RelayLog()
            // 확인하는 시점에 중계는 이미 건강 확인을 마쳤고 글은 아직 쓰지 않았다
            let result = await rig.relay.send(sessionID: target, text: secret, recheck: {
                seen.log("probe", ["pinged": .count(launcher.processes.first?.contents.filter { $0.hasPrefix("/tfping") }.count ?? 0), "sent": .count(launcher.processes.first?.contents.filter { $0.hasPrefix("/tfsend") }.count ?? 0)])
                return false
            })
            #expect(result == .notDelivered(.notReceived), "달라졌으면 보내지 않는다: Not received")
            #expect(seen.events("probe").count == 1 && seen.events("probe")[0]["pinged"] == .count(1) && seen.events("probe")[0]["sent"] == .count(0))
            let process = try #require(rig.launcher.processes.first)
            #expect(process.contents == ["/tfping 0123456789abcdef0123456789abcdef"], "글은 쓰지 않았다")
            let readiness = await rig.relay.readiness()
            #expect(!process.isStopped && readiness == .ready, "중계는 멀쩡하다: 막은 것은 이 보내기뿐이다")
            // 달라진 것이 없으면 간다
            #expect(await rig.relay.send(sessionID: target, text: "fine", recheck: { true }) == .delivered(relayPID: 4001))
        }

        @Test func aTerminalShutdownIsForeverAndEveryWayToStartTheRelayIsRefused() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            await rig.relay.shutdown(terminal: true)
            await rig.relay.retain()
            #expect(await rig.relay.prepare() == false)
            #expect(await rig.relay.send(sessionID: target, text: "late") == .notDelivered(.relayFailed))
            #expect(rig.launcher.launches.isEmpty, "종료가 정해진 뒤에는 띄우지 않는다")
            #expect(await rig.relay.readiness() == .unavailable)
            // 끝내기만 하는 종료는 다음 보내기가 다시 띄운다 (계정이 바뀐 뒤처럼)
            let plain = try makeRig()
            defer { ClaudeAppModFixture.cleanup(plain.mod) }
            await plain.relay.shutdown()
            #expect(await plain.relay.send(sessionID: target, text: "next account") == .delivered(relayPID: 4001))
        }

        @Test func theIdleStopDoesNotKillTheRelayWhileACommandIsStillInFlight() async throws {
            let rig = try makeRig(commandTimeout: 1_000)
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            let process = FakeRelayProcess(pid: 4001) { content, nonce in content.hasPrefix("/tfping ") ? L.ping(nonce: nonce ?? "") : nil }
            rig.launcher.enqueue(process)
            #expect(await rig.relay.prepare(), "쓰는 곳이 없는 채로 준비만 했다: 2분 시계가 선다")
            #expect(await relayEventually { rig.sleeper.requested.contains(120) })
            let sending = Task { await rig.relay.send(sessionID: target, text: "slow") }
            #expect(await relayEventually { process.contents.contains { $0.hasPrefix("/tfsend") } }, "명령이 날아갔고 답을 기다린다")
            rig.sleeper.advance(120)
            try await Task.sleep(for: .milliseconds(60))
            #expect(!process.isStopped, "명령이 도는 동안에는 유휴 시계가 끝내지 못한다")
            process.emit(L.sent(delivered: true))
            #expect(await sending.value == .delivered(relayPID: 4001))
            #expect(await relayEventually { rig.sleeper.requested.filter { $0 == 120 }.count >= 2 }, "끝난 뒤에는 2분 시계가 다시 선다")
        }

        // MARK: 자기 제외

        @Test func theRelaysPidIsPublishedSoTheRailAndTheListLeaveItOut() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            #expect(rig.relay.pids.current.isEmpty)
            _ = await rig.relay.send(sessionID: target, text: "one")
            #expect(rig.relay.pids.current == [4001])
            await rig.relay.shutdown()
            #expect(rig.relay.pids.current.isEmpty)
        }

        @Test func theRelayStartsWithoutAnyUserTextInTheLogOrTheLaunchValues() async throws {
            let rig = try makeRig()
            defer { ClaudeAppModFixture.cleanup(rig.mod) }
            _ = await rig.relay.send(sessionID: target, text: secret)
            let launches = rig.launcher.launches.map { "\($0.arguments) \($0.cwd)" }.joined()
            #expect(!launches.contains("SENTINEL") && !rig.log.text.contains("SENTINEL") && !rig.log.text.contains("5e5e5e5e"))
            let fields = rig.log.entries.flatMap { $0.fields.values }
            #expect(fields.allSatisfy { value in
                switch value {
                case .code(let code): code.wholeMatch(of: /[a-z_]{1,40}/) != nil
                case .count, .millis, .status: true
                case .id: false
                }
            })
        }
    }
}
#endif
