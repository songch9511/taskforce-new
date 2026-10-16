import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 질문 카드의 크기가 디자인 시스템 미리보기와 같은가 (OA D4b-m-1, 시각 확인의 숫자 쪽): DS `QuestionCard/preview.html`을 380 폭 시트에서 그렸을 때 카드(`.tf-qcard`)의 높이를 그대로 적는다
/// (DS 버전 `1792142133-2f29`, 브라우저에서 잰 값). 폭은 시트 안쪽 356이다. 줄 높이 15/20 · 13/18, 줄 40, 간격 6 · 10, 안쪽 12가 모두 맞아야 같은 높이가 된다
@MainActor
struct EdgeQuestionMetricsTests {
    private func height(_ card: AgentQuestionCard, status: QuestionCard.Status = .open, summary: String? = nil, failure: AgentQuestionFailure? = nil, checked: Set<Int> = [], otherOpen: Bool = false, remote: String? = nil) -> CGFloat {
        let view = QuestionCard(card: card, status: status, summary: summary, failure: failure, checked: checked, otherOpen: otherOpen, remoteRow: remote).frame(width: 356)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 356, height: 900)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func rows(_ labels: [String], other: Bool = false) -> [AgentQuestionCard.Row] {
        labels.enumerated().map { .init(label: $0.element, isOther: other && $0.offset == labels.count - 1) }
    }

    private let price = "Which price should lead the yearly card?"
    private var four: [String] { ["First-month price", "Monthly price", "Yearly total", "Price per month"] }

    @Test func eachKindHasTheHeightOfTheDesignSystemPreview() {
        #expect(height(.init(promptID: "q", kind: .single, title: price, meta: "outside the brief", rows: rows(four))) == 262, "Single choice")
        #expect(height(.init(promptID: "q", kind: .multi, title: "Which plans show the 3-day trial?", meta: "Choose any", rows: rows(["Pro monthly", "Pro yearly", "Lifetime"])), checked: [0, 1]) == 246, "Multiple choice")
        #expect(height(.init(promptID: "q", kind: .other, title: "Which plan should the banner mention?", meta: "outside the brief", rows: rows(["Pro monthly", "Pro yearly", "Lifetime", "Other"], other: true))) == 262, "Other")
        #expect(height(.init(promptID: "q", kind: .other, title: "Which plan should the banner mention?", meta: "outside the brief", rows: rows(["Pro monthly", "Pro yearly", "Lifetime", "Other"], other: true)), otherOpen: true) == 262, "Other · typing")
        #expect(height(.init(promptID: "q", kind: .single, title: price, meta: "1 of 3 · outside the brief", position: .init(current: 1, total: 3), rows: rows(four))) == 262, "Several questions")
        #expect(height(.init(promptID: "q", kind: .approval, title: "Edit file", meta: "Claude Code", rows: rows(["Allow", "Deny"]), preview: "Edit src/content/pricing.mdx")) == 210, "Approval")
        #expect(height(.init(promptID: "q", kind: .secret, title: "Enter the staging deploy token", meta: "Stays on this Mac")) == 124, "Secret · this Mac")
        #expect(height(.init(promptID: "q", kind: .secretRemote, title: "Enter the staging deploy token", meta: "Can't be entered here", macName: "Mina's MacBook Pro"), remote: "Answer on Mina's MacBook Pro") == 124, "Secret · other device")
    }

    @Test func theFoldedRowsAndTheFailureLineHaveTheDesignSystemHeights() {
        let single = AgentQuestionCard(promptID: "q", kind: .single, title: price, meta: "outside the brief", rows: rows(four))
        #expect(height(single, status: .holding, summary: "First-month price") == 62, "Just answered")
        #expect(height(single, status: .sent, summary: "First-month price") == 62, "After 2 seconds")
        #expect(height(single, failure: .offline) == 286, "Delivery failed: 한 줄이 18 + 간격 6 더해진다")
    }

    /// 꺼진 보내기 원의 색: DS `.tf-send:disabled`는 잉크 원 + 35% 투명이다. 기본 plain 버튼 스타일은 꺼진 버튼을 한 번 더 흐리게 해 DS보다 옅어졌던 적이 있다(시각 확인에서 드러남)
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theDisabledSendCircleIsTheInkAtThirtyFivePercentAndIsNotDimmedTwice(name: NSAppearance.Name) throws {
        let card = AgentQuestionCard(promptID: "q", kind: .secret, title: "Enter the staging deploy token", meta: "Stays on this Mac")
        let host = NSHostingView(rootView: QuestionCard(card: card, status: .open).frame(width: 356))
        host.appearance = NSAppearance(named: name)
        host.frame = NSRect(x: 0, y: 0, width: 356, height: 900)
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(x: 0, y: 0, width: 356, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width

        // 원의 중심: 카드 안쪽 12 + 입력 줄 오른쪽 안쪽 6 + 반지름 14, 입력 줄은 카드 맨 아래(12 위)의 40 높이
        let center = CGPoint(x: 356 - 12 - 6 - 14, y: host.bounds.height - 12 - 20)
        let ring = (0..<8).map { i -> CGPoint in
            let angle = CGFloat(i) * .pi / 4
            return CGPoint(x: center.x + 10 * cos(angle), y: center.y + 10 * sin(angle))
        }
        func srgb(_ color: Color) -> [CGFloat] {
            var out: [CGFloat] = []
            host.appearance?.performAsCurrentDrawingAppearance {
                let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
                out = [c.redComponent, c.greenComponent, c.blueComponent]
            }
            return out
        }
        let ink = srgb(TFColor.fillInverse)
        let field = srgb(TFColor.bgElevated)
        let expected = zip(ink, field).map { $0 * 0.35 + $1 * 0.65 }
        for point in ring {
            let pixel = try #require(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
            let got = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
            for (g, e) in zip(got, expected) {
                // 잰 값: 라이트 0.737(기대 0.690, DS 웹 미리보기 0.70). 두 번 흐려지면 0.89라 0.08 안이면 한 번만 흐려진 것이다
                #expect(abs(g - e) < 0.08, "원 둘레의 색이 35% 잉크가 아니다 (\(name.rawValue)): 얻은 \(got) 기대 \(expected)")
            }
        }
    }
}
