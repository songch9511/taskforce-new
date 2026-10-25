#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import TaskforceKit
@testable import TaskforceUI

struct AgentTreeCanvasTests {
    private func rows() -> [SubagentTreeRow] {
        var tasks = BackgroundTaskList()
        for (id, parent) in [("a", nil), ("b", nil), ("c", nil), ("d", "a"), ("e", "d"), ("f", "b"), ("g", nil)] as [(String, String?)] {
            tasks.apply(.started(taskID: id, toolUseID: nil, kind: .agent, name: id, at: nil, parentID: parent))
        }
        return SubagentTree.rows(for: tasks, expansion: SubagentTreeExpansion(visibleLevels: 17))
    }

    @Test func everyVisibleNodeHasOneFrameAndNormalizedParentAtEveryWidth() {
        let rows = rows()
        for width: CGFloat in [320, 380, 510, 784] {
            let plan = AgentTreeGeometry.layout(rows: rows, width: width)
            #expect(Set(plan.nodes.map(\.id)) == Set(rows.map(\.id)))
            let positions = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0.rect) })
            for node in plan.nodes {
                #expect(node.rect.minX >= 0 && node.rect.maxX <= width)
                #expect(node.rect.maxY <= plan.height)
                #expect(node.parent == AgentTreeCanvas.rootID || positions[node.parent] != nil)
                for other in plan.nodes where other.id != node.id {
                    #expect(!node.rect.intersects(other.rect))
                    if other.id != node.parent {
                        let path = AgentTreeGeometry.connection(node, in: plan)
                        for (a, b) in zip(path, path.dropFirst()) {
                            let segment = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: max(0.1, abs(a.x - b.x)), height: max(0.1, abs(a.y - b.y)))
                            #expect(!other.rect.insetBy(dx: 1, dy: 1).intersects(segment))
                        }
                    }
                }
            }
            #expect(plan.nodes.first(where: { $0.id == "e" })?.parent == "d")
        }
    }

    @Test func collapsedBranchDoesNotLeaveGhostNodesOrConnections() {
        var list = BackgroundTaskList()
        list.apply(.started(taskID: "a", toolUseID: nil, kind: .agent, name: "Parent", at: nil))
        list.apply(.started(taskID: "b", toolUseID: nil, kind: .agent, name: "Child", at: nil, parentID: "a"))
        var expansion = SubagentTreeExpansion(visibleLevels: 17)
        expansion.toggle(id: "a", level: 0)
        let plan = AgentTreeGeometry.layout(rows: SubagentTree.rows(for: list, expansion: expansion), width: 784)
        #expect(plan.nodes.map(\.id) == ["a"])
        #expect(plan.nodes[0].parent == AgentTreeCanvas.rootID)
    }

    @Test func cyclicMetadataUsesT1NormalizationInsteadOfDrawingACycle() {
        var list = BackgroundTaskList()
        for (id, parent) in [("a", "b"), ("b", "a")] {
            list.apply(.started(taskID: id, toolUseID: nil, kind: .agent, name: id, at: nil, parentID: parent))
        }
        let plan = AgentTreeGeometry.layout(rows: SubagentTree.rows(for: list, expansion: SubagentTreeExpansion(visibleLevels: 17)), width: 784)
        #expect(plan.nodes.allSatisfy { $0.parent == AgentTreeCanvas.rootID })
    }

    @Test func extremePansKeepTheDiagramReachableAndCenterRemainsValid() {
        let viewport = CGSize(width: 380, height: 460)
        let plan = AgentTreeGeometry.layout(rows: rows(), width: 784)
        let originX = (viewport.width - 784) / 2
        let content = plan.nodes.reduce(plan.root) { $0.union($1.rect) }.offsetBy(dx: originX, dy: 0)
        for proposed in [CGSize(width: -10_000, height: -10_000), CGSize(width: 10_000, height: 10_000), .zero] {
            let pan = AgentTreePan.clamp(proposed, viewport: viewport, content: content)
            let visible = content.offsetBy(dx: pan.width, dy: pan.height).intersection(CGRect(origin: .zero, size: viewport))
            #expect(visible.width >= 64 && visible.height >= 64)
        }
        #expect(AgentTreePan.clamp(.zero, viewport: viewport, content: content) == .zero)
    }

    @Test func keyboardFocusRevealsAnOffscreenCardWithoutResettingAnAlreadyVisibleCard() {
        let viewport = CGSize(width: 380, height: 460)
        let content = CGRect(x: -180, y: 12, width: 740, height: 900)
        let card = CGRect(x: 390, y: 700, width: 180, height: 104)
        let pan = AgentTreePan.revealing(card, offset: .zero, viewport: viewport, content: content)
        let visibleCard = card.offsetBy(dx: pan.width, dy: pan.height)
        #expect(visibleCard.minX >= 20 && visibleCard.maxX <= viewport.width - 20)
        #expect(visibleCard.minY >= 20 && visibleCard.maxY <= viewport.height - 20)
        #expect(AgentTreePan.revealing(card, offset: pan, viewport: viewport, content: content) == pan)
    }

    @Test func panningClampsAgainWhenTheCanvasShrinks() {
        let viewport = CGSize(width: 380, height: 300)
        let root = CGRect(x: 82, y: 12, width: 216, height: 104)
        let pan = AgentTreePan.clamp(CGSize(width: -900, height: -900), viewport: viewport, content: root)
        let visible = root.offsetBy(dx: pan.width, dy: pan.height).intersection(CGRect(origin: .zero, size: viewport))
        #expect(visible.width >= 64 && visible.height >= 64)
    }

    @Test func fittingIncludesEveryCardAndWrappedConnectorWithPadding() {
        let plan = AgentTreeGeometry.layout(rows: rows(), width: 720)
        let bounds = AgentTreeGeometry.bounds(of: plan)
        for viewport in [CGSize(width: 463, height: 480), CGSize(width: 320, height: 180), CGSize(width: 900, height: 700)] {
            let transform = AgentTreeTransform.fit(content: bounds, viewport: viewport)
            let shown = transform.shown(bounds)
            #expect(shown.minX >= 19.999 && shown.minY >= 19.999)
            #expect(shown.maxX <= viewport.width - 19.999 && shown.maxY <= viewport.height - 19.999)
            for node in plan.nodes {
                #expect(bounds.contains(node.rect))
                for point in AgentTreeGeometry.connection(node, in: plan) { #expect(bounds.contains(point)) }
            }
        }
    }

    @Test func fittingAHugeTreeCanGoBelowTheManualZoomMinimum() {
        let bounds = CGRect(x: 8, y: 12, width: 704, height: 12_000)
        let viewport = CGSize(width: 463, height: 480)
        let fit = AgentTreeTransform.fit(content: bounds, viewport: viewport)
        #expect(fit.scale < AgentTreeTransform.minimumZoom)
        #expect(fit.shown(bounds).maxY <= viewport.height - 19.999)
    }

    @Test func zoomKeepsTheAnchorFixedAndCapsManualScale() {
        let content = CGRect(x: 0, y: 0, width: 720, height: 600)
        let viewport = CGSize(width: 463, height: 480)
        let initial = AgentTreeTransform.fit(content: content, viewport: viewport)
        let anchor = CGPoint(x: 170, y: 190)
        let worldPoint = CGPoint(x: (anchor.x - initial.offset.width) / initial.scale, y: (anchor.y - initial.offset.height) / initial.scale)
        let zoomed = initial.zoomed(to: 1.2, anchor: anchor, content: content, viewport: viewport)
        #expect(abs(worldPoint.x * zoomed.scale + zoomed.offset.width - anchor.x) < 0.001)
        #expect(abs(worldPoint.y * zoomed.scale + zoomed.offset.height - anchor.y) < 0.001)
        #expect(initial.zoomed(to: 20, anchor: anchor, content: content, viewport: viewport).scale == 1.5)
        #expect(initial.zoomed(to: 0.01, anchor: anchor, content: content, viewport: viewport).scale == 0.25)
    }

    @Test func zoomFromTinyFitNeverReversesDirectionOrJumpsToManualMinimum() {
        let content = CGRect(x: 8, y: 12, width: 704, height: 12_000)
        let viewport = CGSize(width: 463, height: 480)
        let fit = AgentTreeTransform.fit(content: content, viewport: viewport)
        let anchor = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let outward = fit.zoomed(to: fit.scale * 0.9, anchor: anchor, content: content, viewport: viewport)
        #expect(outward.scale == fit.scale)
        let inward = fit.zoomed(to: fit.scale * 1.1, anchor: anchor, content: content, viewport: viewport)
        #expect(abs(inward.scale - fit.scale * 1.1) < 0.000001)
        #expect(inward.scale < AgentTreeTransform.minimumZoom)
        let worldX = (anchor.x - fit.offset.width) / fit.scale
        let worldY = (anchor.y - fit.offset.height) / fit.scale
        #expect(abs(worldX * inward.scale + inward.offset.width - anchor.x) < 0.001)
        #expect(abs(worldY * inward.scale + inward.offset.height - anchor.y) < 0.001)
    }

    @Test func keyboardRevealUsesScaledCardCoordinates() {
        let content = CGRect(x: 0, y: 0, width: 720, height: 900)
        let viewport = CGSize(width: 463, height: 480)
        let card = CGRect(x: 480, y: 760, width: 200, height: 96)
        let transform = AgentTreeTransform(scale: 0.75, offset: .zero)
        let revealed = transform.revealing(card, content: content, viewport: viewport)
        let shown = revealed.shown(card)
        #expect(shown.minX >= 20 && shown.maxX <= viewport.width - 20)
        #expect(shown.minY >= 20 && shown.maxY <= viewport.height - 20)
        #expect(revealed.scale == transform.scale)
        #expect(revealed.revealing(card, content: content, viewport: viewport) == revealed)
    }

    @MainActor @Test func scrollMonitorIsBoundedToTheHostedTreeViewport() async throws {
        let tree = AgentTreeCanvas(root: AgentTreeRoot(title: "Session", agent: .claudeCode),
                                   rows: rows(), now: Date(), rootExpanded: .constant(true),
                                   focusedID: .constant(nil), onOpen: { _ in }, onToggle: { _ in })
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            tree.frame(width: 463)
            Color.clear.frame(width: 321)
        }.frame(width: 784, height: 640))
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 784, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func input(in view: NSView) -> AgentTreeScrollInput.InputView? {
            if let input = view as? AgentTreeScrollInput.InputView { return input }
            return view.subviews.lazy.compactMap { input(in: $0) }.first
        }
        for _ in 0..<100 where input(in: host) == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        host.layoutSubtreeIfNeeded()
        let monitor = try #require(input(in: host))
        let visible = monitor.convert(monitor.bounds.intersection(monitor.visibleRect), to: nil)
        #expect(visible.minX >= 0 && visible.maxX <= 463)
        #expect(monitor.containsScrollLocation(CGPoint(x: 230, y: 320)))
        // Real QA coordinates: x=1240 at 2x backing scale is in the adjacent chat.
        #expect(!monitor.containsScrollLocation(CGPoint(x: 620, y: 350)))
        let pinch = try #require(monitor.magnifyRecognizer)
        #expect(pinch.view === host)
        #expect(host.gestureRecognizers.contains { $0 === pinch })
        #expect(pinch.delegate === monitor)
        for (point, expected) in [(CGPoint(x: 230, y: 320), true), (CGPoint(x: 620, y: 350), false)] {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            #expect(monitor.gestureRecognizer(pinch, shouldAttemptToRecognizeWith: event) == expected)
        }
        #expect(!pinch.delaysPrimaryMouseButtonEvents)
        monitor.enabled = false
        #expect(!pinch.isEnabled)
        monitor.enabled = true
        #expect(pinch.isEnabled)
        monitor.stop()
        #expect(!host.gestureRecognizers.contains { $0 === pinch })
        #expect(monitor.magnifyRecognizer == nil)
    }

    @MainActor private final class Pinch: NSMagnificationGestureRecognizer {
        var testLocation = CGPoint.zero
        private var testState = NSGestureRecognizer.State.changed
        override var state: NSGestureRecognizer.State {
            get { testState }
            set { testState = newValue }
        }
        override func location(in view: NSView?) -> NSPoint { testLocation }
    }

    @MainActor @Test func nativeRecognizerKeepsItsAnchorAndResetsItsIncrement() throws {
        let input = AgentTreeScrollInput.InputView(frame: CGRect(x: 0, y: 0, width: 463, height: 480))
        let pinch = Pinch()
        let tree = CGPoint(x: 200, y: 180), chat = CGPoint(x: 600, y: 180)
        var increments: [CGFloat] = [], anchors: [CGPoint] = []
        input.onMagnify = { increments.append($0); anchors.append($1) }
        func begin(at point: CGPoint) throws -> Bool {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: input.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            _ = input.gestureRecognizer(pinch, shouldAttemptToRecognizeWith: event)
            // Reproduce hardware logs: recognizer location is outside, event location is inside.
            pinch.testLocation = CGPoint(x: 0, y: 560)
            return input.gestureRecognizerShouldBegin(pinch)
        }

        pinch.testLocation = chat
        #expect(try !begin(at: chat))
        pinch.magnification = 0.1
        input.magnificationChanged(pinch)
        #expect(increments.isEmpty)
        pinch.testLocation = tree
        #expect(try begin(at: tree))
        input.magnificationChanged(pinch)
        #expect(pinch.magnification == 0)
        pinch.testLocation = chat
        pinch.magnification = -0.05
        input.magnificationChanged(pinch)
        #expect(increments == [0.1, -0.05])
        #expect(anchors == [tree, tree])
        pinch.state = .cancelled
        pinch.magnification = 0.5
        input.magnificationChanged(pinch)
        pinch.state = .changed
        input.magnificationChanged(pinch)
        #expect(increments == [0.1, -0.05])
        pinch.testLocation = tree
        #expect(try begin(at: tree))
        pinch.state = .ended
        pinch.magnification = 0
        input.magnificationChanged(pinch)
        pinch.state = .changed
        pinch.magnification = 0.5
        input.magnificationChanged(pinch)
        #expect(increments == [0.1, -0.05])
    }

    @MainActor @Test func momentumStaysWithItsOriginAndOrdinaryScrollUsesBothAxes() {
        let input = AgentTreeScrollInput.InputView(frame: CGRect(x: 0, y: 0, width: 463, height: 480))
        let tree = CGPoint(x: 200, y: 180), chat = CGPoint(x: 600, y: 180)
        var deltas: [CGSize] = []
        input.onScroll = { deltas.append($0) }
        let delta = CGSize(width: 12, height: -8)
        #expect(input.receive(type: .scrollWheel, location: tree, scroll: delta))
        #expect(deltas == [delta])
        #expect(!input.receive(type: .scrollWheel, momentum: .began, location: chat, scroll: delta))
        #expect(!input.receive(type: .scrollWheel, momentum: .changed, location: tree, scroll: delta))
        #expect(!input.receive(type: .scrollWheel, momentum: .ended, location: tree))
        #expect(input.receive(type: .scrollWheel, momentum: .began, location: tree, scroll: delta))
        #expect(input.receive(type: .scrollWheel, momentum: .changed, location: chat, scroll: delta))
        #expect(input.receive(type: .scrollWheel, momentum: .cancelled, location: chat))
        #expect(!input.receive(type: .scrollWheel, momentum: .changed, location: tree, scroll: delta))
        #expect(deltas == [delta, delta, delta])
    }

    @MainActor @Test func chatScrollCannotBeAcquiredMidGestureOrAtMomentumStart() {
        let input = AgentTreeScrollInput.InputView(frame: CGRect(x: 0, y: 0, width: 463, height: 480))
        let tree = CGPoint(x: 200, y: 180), chat = CGPoint(x: 600, y: 180)
        var count = 0
        input.onScroll = { _ in count += 1 }
        #expect(!input.receive(type: .scrollWheel, phase: .began, location: chat))
        #expect(!input.receive(type: .scrollWheel, phase: .changed, location: tree))
        #expect(!input.receive(type: .scrollWheel, phase: .ended, location: tree))
        #expect(!input.receive(type: .scrollWheel, momentum: .began, location: tree))
        #expect(!input.receive(type: .scrollWheel, momentum: .ended, location: tree))
        #expect(count == 0)
        #expect(input.receive(type: .scrollWheel, phase: .began, location: tree))
        #expect(input.receive(type: .scrollWheel, phase: .changed, location: chat))
        #expect(input.receive(type: .scrollWheel, phase: .ended, location: chat))
        #expect(input.receive(type: .scrollWheel, momentum: .began, location: chat))
        #expect(input.receive(type: .scrollWheel, momentum: .ended, location: chat))
        #expect(count == 5)
    }

    @MainActor @Test func smartZoomAndPinchRespectCanvasActivation() throws {
        let input = AgentTreeScrollInput.InputView(frame: CGRect(x: 0, y: 0, width: 463, height: 480))
        let tree = CGPoint(x: 200, y: 180)
        var fits = 0
        input.onFit = { fits += 1 }
        #expect(!input.receive(type: .smartMagnify, location: CGPoint(x: 600, y: 180)))
        #expect(input.receive(type: .smartMagnify, location: tree))
        #expect(fits == 1)
        let pinch = Pinch()
        pinch.testLocation = tree
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: input.convert(tree, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        #expect(input.gestureRecognizer(pinch, shouldAttemptToRecognizeWith: event))
        #expect(input.gestureRecognizerShouldBegin(pinch))
        input.enabled = false
        #expect(!input.receive(type: .smartMagnify, location: tree))
        input.enabled = true
        var magnified = false
        input.onMagnify = { _, _ in magnified = true }
        pinch.magnification = 0.1
        input.magnificationChanged(pinch)
        #expect(!magnified)
        #expect(fits == 1)
    }

    @MainActor @Test func trackpadPreflightRemainsViewportScoped() {
        let input = AgentTreeScrollInput.InputView(frame: CGRect(x: 0, y: 0, width: 463, height: 480))
        let tree = CGPoint(x: 200, y: 180), chat = CGPoint(x: 600, y: 180)
        var deltas: [CGSize] = []
        input.onScroll = { deltas.append($0) }
        #expect(input.receive(type: .scrollWheel, phase: .mayBegin, location: tree))
        #expect(input.receive(type: .scrollWheel, phase: .changed, location: tree, scroll: CGSize(width: 12, height: -8)))
        #expect(deltas.last == CGSize(width: 12, height: -8))
        #expect(!input.receive(type: .scrollWheel, phase: .mayBegin, location: chat))
        #expect(!input.receive(type: .scrollWheel, phase: .changed, location: tree))
    }

}
#endif
