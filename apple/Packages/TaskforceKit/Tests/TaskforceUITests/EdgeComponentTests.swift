import Testing
@testable import TaskforceUI

/// 0.2.0 Edge 셸 부품의 순수 규칙: 움직임 상수 · 레일 칸 · 패널 머리의 접근성 이름
struct EdgeComponentTests {
    /// 이징 하나(cubic-bezier(.22, 1, .36, 1))와 디자인 README › Motion의 시간
    @Test func motionMatchesTheDesign() {
        #expect(TFMotion.easeControlPoints == (0.22, 1, 0.36, 1))
        #expect(TFMotion.panelFade == 0.18)
        #expect(TFMotion.panelMove == 0.26)
        #expect(TFMotion.railHoverDelay == 0.12)
        #expect(TFMotion.railSlide == 0.22)
        #expect(TFMotion.railLeaveDelay == 0.4)
        #expect(TFMotion.ringFade == 0.16)
        // 3초는 끝남을 시간으로 내리는 옛 모드(노치 레일 · Assistant 창의 좁은 저장소)만 쓴다. 캡슐 레일의 끝난 링은 열어 볼 때까지 남는다 (OA PR-D2, 계약 23장)
        #expect(TFMotion.doneHold == 3)
        #expect(TFMotion.disclosureFlip == 0.2)
        #expect(TFMotion.pressScale == 0.98)
    }

    /// 링이 도는 시간은 Activity ring과 같다 (Running 1.1초 · Stop requested 2.4초, 나머지는 멈춤)
    @Test func ringPeriodsComeFromOnePlace() {
        #expect(ActivityRing.Kind.running.period == TFMotion.runningTurn)
        #expect(ActivityRing.Kind.stopping.period == TFMotion.stoppingTurn)
        for kind in ActivityRing.Kind.allCases where kind != .running && kind != .stopping {
            #expect(kind.period == nil)
        }
    }

    /// 움직임 줄이기: Running은 반 링, Stop requested는 3/4 링으로 멈춰 서로 구분된다
    @Test func reducedMotionRingsStayDistinct() {
        #expect(ActivityRing.Kind.running.arcLength(reduceMotion: true) == 0.55)
        #expect(ActivityRing.Kind.stopping.arcLength(reduceMotion: true) == 0.75)
        #expect(ActivityRing.Kind.unreachable.arcLength(reduceMotion: true) == 0.5)
    }

    @Test func railItemNameIsTitleStateActivity() {
        #expect(RailItem.accessibilityLabel(title: "Pricing page", state: .inProgress, activity: "AI reviewing") == "Pricing page · In Progress · AI reviewing")
        #expect(RailItem.accessibilityLabel(title: "Launch", state: .done, activity: "Done just now") == "Launch · Done · Done just now")
        #expect(RailItem.accessibilityLabel(title: "Launch", state: .done, activity: "Done") == "Launch · Done · Done", "열어 볼 때까지 남는 끝난 링의 활동은 \"Done\"")
        #expect(RailItem.side == 32)
    }

    /// 업무 상태가 없는 칸(Claude 데스크톱 세션)은 "제목 · 활동"이다 (Taskforce 업무가 아니라 To Do · In Progress · Done을 붙이지 않는다)
    @Test func aRailItemWithoutAWorkStateIsNamedByTitleAndActivity() {
        #expect(RailItem.accessibilityLabel(title: "Pricing draft", state: nil, activity: "Running") == "Pricing draft · Running")
        #expect(RailItem.accessibilityLabel(title: "Pricing draft", state: nil, activity: "Done") == "Pricing draft · Done")
        for state in TaskStatusMark.State.allCases {
            #expect(!RailItem.accessibilityLabel(title: "Pricing draft", state: nil, activity: "Running").contains(state.label), "업무 상태 낱말이 붙지 않는다")
        }
    }

    @Test func panelHeaderStepsSayThePosition() {
        #expect(PanelHeader.Steps(count: 3, current: 0).accessibilityLabel == "Review item 1 of 3")
    }
}
