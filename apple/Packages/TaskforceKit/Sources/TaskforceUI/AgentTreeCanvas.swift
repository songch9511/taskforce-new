#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit

/// Presentation only. Hierarchy and collapse semantics come from `SubagentTree.rows`.
public struct AgentTreeRoot {
    public let title: String
    public let agent: AgentMarkKind
    public let status: BackgroundTaskStatus?
    public let elapsed: String?

    public init(title: String, agent: AgentMarkKind, status: BackgroundTaskStatus? = nil, elapsed: String? = nil) {
        self.title = title
        self.agent = agent
        self.status = status
        self.elapsed = elapsed
    }
}

/// Geometry consumes normalized preorder rows, including T1's orphan/cycle handling.
/// Only first-level branches form columns; descendants remain with their own branch.
enum AgentTreeGeometry {
    struct Node: Identifiable {
        let id: String
        let rect: CGRect
        let parent: String
    }
    struct Plan {
        let root: CGRect
        let nodes: [Node]
        let height: CGFloat
    }

    /// Orthogonal routes keep wrapped sibling edges in the outer gutter.
    static func connection(_ node: Node, in plan: Plan) -> [CGPoint] {
        let parent = plan.nodes.first { $0.id == node.parent }?.rect ?? plan.root
        let fromRoot = node.parent == AgentTreeCanvas.rootID
        let start = fromRoot ? CGPoint(x: parent.midX, y: parent.maxY) : CGPoint(x: parent.minX + 12, y: parent.maxY)
        let end = fromRoot ? CGPoint(x: node.rect.midX, y: node.rect.minY) : CGPoint(x: node.rect.minX, y: node.rect.minY + 26)
        var points: [CGPoint]
        if fromRoot {
            let bus = plan.root.maxY + 16
            let firstRow = plan.nodes.filter { $0.parent == AgentTreeCanvas.rootID }.map { $0.rect.minY }.min() ?? node.rect.minY
            if node.rect.minY > firstRow {
                let gutter: CGFloat = 8
                points = [start, CGPoint(x: start.x, y: bus), CGPoint(x: gutter, y: bus), CGPoint(x: gutter, y: end.y - 16), CGPoint(x: end.x, y: end.y - 16), end]
            } else {
                points = [start, CGPoint(x: start.x, y: bus), CGPoint(x: end.x, y: bus), end]
            }
        } else {
            let spine = node.rect.minX - 7
            points = [start, CGPoint(x: spine, y: start.y), CGPoint(x: spine, y: end.y), end]
        }
        return points.enumerated().compactMap { index, point in index == 0 || point != points[index - 1] ? point : nil }
    }

    static func bounds(of plan: Plan) -> CGRect {
        var bounds = plan.nodes.reduce(plan.root) { $0.union($1.rect) }
        for node in plan.nodes {
            for point in connection(node, in: plan) {
                bounds = bounds.union(CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
            }
        }
        return bounds
    }

    static func layout(rows: [SubagentTreeRow], width: CGFloat, rootHasSummary: Bool = false) -> Plan {
        let columns = width >= 720 ? 3 : width >= 500 ? 2 : 1
        let gap: CGFloat = 24
        let inset: CGFloat = 24
        let available = max(240, width - inset * 2)
        let cell = min(216, (available - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let groupWidth = CGFloat(columns) * cell + CGFloat(columns - 1) * gap
        let origin = (width - groupWidth) / 2
        let root = CGRect(x: (width - cell) / 2, y: 12, width: cell, height: rootHasSummary ? 108 : 96)
        var groups: [[SubagentTreeRow]] = []
        for row in rows {
            if row.level == 0 || groups.isEmpty { groups.append([]) }
            groups[groups.count - 1].append(row)
        }
        var nodes: [Node] = []
        var y: CGFloat = root.maxY + 32
        for start in stride(from: 0, to: groups.count, by: columns) {
            let batch = groups[start..<min(start + columns, groups.count)]
            var bottom = y
            for (column, group) in batch.enumerated() {
                var nextY = y
                var ancestors: [Int: String] = [:]
                for row in group {
                    let indent = CGFloat(min(row.level, 3)) * 14
                    let height: CGFloat = row.branchSummary == nil ? 96 : 108
                    let rect = CGRect(x: origin + CGFloat(column) * (cell + gap) + indent, y: nextY, width: cell - indent, height: height)
                    let parent = row.level == 0 ? AgentTreeCanvas.rootID : ancestors[row.level - 1] ?? AgentTreeCanvas.rootID
                    nodes.append(Node(id: row.id, rect: rect, parent: parent))
                    ancestors[row.level] = row.id
                    nextY = rect.maxY + 14
                }
                bottom = max(bottom, nextY)
            }
            y = bottom + 24
        }
        return Plan(root: root, nodes: nodes, height: max(root.maxY + 24, y))
    }
}

/// Keep some of the diagram reachable even after a long drag or momentum scroll.
enum AgentTreePan {
    static func clamp(_ offset: CGSize, viewport: CGSize, content: CGRect) -> CGSize {
        let visible: CGFloat = 64
        let minX = min(0, visible - content.maxX)
        let maxX = max(0, viewport.width - visible - content.minX)
        let minY = min(0, visible - content.maxY)
        let maxY = max(0, viewport.height - visible - content.minY)
        return CGSize(width: min(max(offset.width, minX), maxX), height: min(max(offset.height, minY), maxY))
    }

    static func revealing(_ rect: CGRect, offset: CGSize, viewport: CGSize, content: CGRect) -> CGSize {
        var next = offset
        let shown = rect.offsetBy(dx: offset.width, dy: offset.height)
        let margin: CGFloat = 20
        if shown.minX < margin { next.width += margin - shown.minX }
        else if shown.maxX > viewport.width - margin { next.width -= shown.maxX - viewport.width + margin }
        if shown.minY < margin { next.height += margin - shown.minY }
        else if shown.maxY > viewport.height - margin { next.height -= shown.maxY - viewport.height + margin }
        return clamp(next, viewport: viewport, content: content)
    }
}

/// Canvas-space points become viewport points via `point * scale + offset`.
struct AgentTreeTransform: Equatable {
    var scale: CGFloat = 1
    var offset = CGSize.zero
    static let minimumZoom: CGFloat = 0.25
    static let maximumZoom: CGFloat = 1.5

    func scaled(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }
    func shown(_ rect: CGRect) -> CGRect { scaled(rect).offsetBy(dx: offset.width, dy: offset.height) }

    static func fit(content: CGRect, viewport: CGSize, padding: CGFloat = 20) -> Self {
        let width = max(1, viewport.width - 2 * padding)
        let height = max(1, viewport.height - 2 * padding)
        let scale = min(1, width / max(1, content.width), height / max(1, content.height))
        return Self(scale: scale, offset: CGSize(width: viewport.width / 2 - content.midX * scale, height: viewport.height / 2 - content.midY * scale))
    }
    func panned(by delta: CGSize, content: CGRect, viewport: CGSize) -> Self {
        Self(scale: scale, offset: AgentTreePan.clamp(CGSize(width: offset.width + delta.width, height: offset.height + delta.height), viewport: viewport, content: scaled(content)))
    }
    func zoomed(to proposed: CGFloat, anchor: CGPoint, content: CGRect, viewport: CGSize) -> Self {
        let nextScale = min(Self.maximumZoom, max(min(Self.minimumZoom, scale), proposed))
        let ratio = nextScale / max(scale, 0.000001)
        let next = Self(scale: nextScale, offset: CGSize(width: anchor.x - (anchor.x - offset.width) * ratio, height: anchor.y - (anchor.y - offset.height) * ratio))
        return next.panned(by: .zero, content: content, viewport: viewport)
    }
    func revealing(_ rect: CGRect, content: CGRect, viewport: CGSize) -> Self {
        Self(scale: scale, offset: AgentTreePan.revealing(scaled(rect), offset: offset, viewport: viewport, content: scaled(content)))
    }
}

/// A viewport-local monitor receives two-axis trackpad scrolling over cards as well
/// as blank space. It leaves other windows and neighboring conversation panes alone.
struct AgentTreeScrollInput: NSViewRepresentable {
    let enabled: Bool
    let onScroll: (CGSize) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void = { _, _ in }
    var onFit: () -> Void = {}

    final class InputView: NSView {
        var onScroll: ((CGSize) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onFit: (() -> Void)?
        var monitor: Any?
        var enabled = true {
            didSet { if !enabled { resetGestures() } }
        }
        private var magnifyAnchor: CGPoint?
        private var momentumOwned: Bool?
        private var scrollOwned: Bool?
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let multiplier: CGFloat = event.type == .scrollWheel && !event.hasPreciseScrollingDeltas ? 10 : 1
                let handled = self.receive(type: event.type, phase: event.type == .smartMagnify ? [] : event.phase,
                                           momentum: event.type == .scrollWheel ? event.momentumPhase : [],
                                           location: self.convert(event.locationInWindow, from: nil),
                                           scroll: event.type == .scrollWheel ? CGSize(width: event.scrollingDeltaX * multiplier, height: event.scrollingDeltaY * multiplier) : .zero,
                                           magnification: event.type == .magnify ? event.magnification : 0)
                return handled ? nil : event
            }
        }

        /// Keep a pinch anchored for its whole sequence and momentum with its origin.
        /// Native magnification is incremental, unlike SwiftUI's gesture-total value.
        @discardableResult
        func receive(type: NSEvent.EventType, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [],
                     location: CGPoint, scroll: CGSize = .zero, magnification: CGFloat = 0) -> Bool {
            guard enabled, !isHiddenOrHasHiddenAncestor else { resetGestures(); return false }
            let inside = bounds.intersection(visibleRect).contains(location)
            switch type {
            case .magnify:
                // Accept trackpad preflight and magnification events without a phase.
                // Keep the origin once established so a chat gesture cannot enter the tree.
                if phase.contains(.mayBegin) || phase.contains(.began) { magnifyAnchor = inside ? location : nil }
                if phase.isEmpty {
                    guard inside else { return false }
                    if magnification != 0 { onMagnify?(magnification, location) }
                    return true
                }
                let anchor = magnifyAnchor
                if phase.contains(.ended) || phase.contains(.cancelled) { magnifyAnchor = nil }
                guard let anchor else { return false }
                if !phase.contains(.cancelled), magnification != 0 { onMagnify?(magnification, anchor) }
                return true
            case .smartMagnify:
                guard inside else { return false }
                resetGestures()
                onFit?()
                return true
            case .scrollWheel:
                if phase.contains(.mayBegin) || phase.contains(.began) { scrollOwned = inside; momentumOwned = nil }
                if momentum.contains(.began) { momentumOwned = scrollOwned ?? inside }
                let owned: Bool
                if !momentum.isEmpty { owned = momentumOwned ?? false }
                else if !phase.isEmpty { owned = scrollOwned ?? false }
                else { owned = inside; scrollOwned = nil; momentumOwned = nil }
                // Retain the direct gesture's origin across .ended → momentum .began.
                if phase.contains(.cancelled) || momentum.contains(.ended) || momentum.contains(.cancelled) {
                    scrollOwned = nil; momentumOwned = nil
                }
                guard owned else { return false }
                if !phase.contains(.cancelled), !momentum.contains(.cancelled) { onScroll?(scroll) }
                return true
            default: return false
            }
        }

        func containsScrollLocation(_ locationInWindow: NSPoint) -> Bool {
            // SwiftUI can report a visibleRect larger than the representable.
            bounds.intersection(visibleRect).contains(convert(locationInWindow, from: nil))
        }
        private func resetGestures() { magnifyAnchor = nil; momentumOwned = nil; scrollOwned = nil }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            resetGestures()
        }
    }

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: InputView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onFit = onFit
        view.enabled = enabled
    }
    static func dismantleNSView(_ view: InputView, coordinator: ()) {
        view.stop(); view.onScroll = nil; view.onMagnify = nil; view.onFit = nil
    }
}

public struct AgentTreeCanvas: View {
    nonisolated public static let rootID = "__session_root__"
    let root: AgentTreeRoot
    let rows: [SubagentTreeRow]
    let now: Date
    @Binding var rootExpanded: Bool
    @Binding var focusedID: String?
    let onOpen: (String?) -> Void
    let onToggle: (SubagentTreeRow) -> Void
    let onCollapse: (() -> Void)?
    let selectedID: String?
    let isActive: Bool
    @State private var manualTransform = AgentTreeTransform()
    @State private var fitMode = true
    @State private var dragStart: AgentTreeTransform?
    @State private var hoveredID: String?
    @FocusState private var keyboardFocus: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(root: AgentTreeRoot, rows: [SubagentTreeRow], now: Date,
                rootExpanded: Binding<Bool>, focusedID: Binding<String?>,
                onOpen: @escaping (String?) -> Void, onToggle: @escaping (SubagentTreeRow) -> Void,
                onCollapse: (() -> Void)? = nil, selectedID: String? = nil, isActive: Bool = true) {
        self.root = root
        self.rows = rows
        self.now = now
        self._rootExpanded = rootExpanded
        self._focusedID = focusedID
        self.onOpen = onOpen
        self.onToggle = onToggle
        self.onCollapse = onCollapse
        self.selectedID = selectedID
        self.isActive = isActive
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "person.2").font(.system(size: 12))
                Text("Agents").font(TFFont.footnoteEmphasis)
                Spacer()
                Button("Collapse tree") {
                    if let onCollapse { onCollapse() }
                    else { focusedID = Self.rootID; onOpen(nil) }
                }
                    .buttonStyle(.plain)
                    .font(TFFont.caption)
                    .foregroundStyle(TFColor.textSecondary)
                    .accessibilityIdentifier("agent-tree-toggle")
            }
            .foregroundStyle(TFColor.textSecondary)
            .padding(.horizontal, 20).padding(.vertical, 14)
            GeometryReader { available in
                let viewport = CGSize(width: available.size.width, height: max(1, available.size.height - 38))
                let plan = AgentTreeGeometry.layout(rows: rootExpanded ? rows : [], width: max(720, viewport.width), rootHasSummary: rootSummary != nil)
                let bounds = AgentTreeGeometry.bounds(of: plan)
                let transform = currentTransform(content: bounds, viewport: viewport)
                VStack(spacing: 0) {
                    pannableDiagram(plan, viewport: viewport, bounds: bounds, transform: transform)
                    zoomControls(transform: transform, content: bounds, viewport: viewport)
                }
            }

        }
        .background(TFColor.bgCanvas)
        .accessibilityIdentifier("agent-tree")
        .onChange(of: focusedID) { _, id in keyboardFocus = id }
        .onChange(of: keyboardFocus) { _, id in if let id { focusedID = id } }
    }

    private var rootSummary: String? {
        !rootExpanded && rows.contains(where: { $0.task.status == .failed || $0.branchSummary?.contains("Failed") == true }) ? "Failed sub-agent" : nil
    }

    private func currentTransform(content: CGRect, viewport: CGSize) -> AgentTreeTransform {
        fitMode ? .fit(content: content, viewport: viewport) : manualTransform
    }

    private func applyManual(_ transform: AgentTreeTransform) {
        fitMode = false
        manualTransform = transform
    }

    private func zoomControls(transform: AgentTreeTransform, content: CGRect, viewport: CGSize) -> some View {
        HStack(spacing: 10) {
            Button("Fit tree") { fitMode = true; dragStart = nil }
                .keyboardShortcut("0", modifiers: .command)
                .accessibilityIdentifier("agent-tree-center")
                .help("Fit tree (⌘0)")
            Spacer(minLength: 8)
            Button {
                let current = currentTransform(content: content, viewport: viewport)
                applyManual(current.zoomed(to: current.scale / 1.2, anchor: CGPoint(x: viewport.width / 2, y: viewport.height / 2), content: content, viewport: viewport))
            } label: { Image(systemName: "minus").frame(width: 22, height: 24).contentShape(Rectangle()) }
            .accessibilityLabel("Zoom out")
            .accessibilityIdentifier("agent-tree-zoom-out")
            .disabled(transform.scale <= AgentTreeTransform.minimumZoom)
            Text("\(Int((transform.scale * 100).rounded()))%")
                .monospacedDigit().frame(minWidth: 34)
                .accessibilityLabel("Zoom \(Int((transform.scale * 100).rounded())) percent")
            Button {
                let current = currentTransform(content: content, viewport: viewport)
                applyManual(current.zoomed(to: current.scale * 1.2, anchor: CGPoint(x: viewport.width / 2, y: viewport.height / 2), content: content, viewport: viewport))
            } label: { Image(systemName: "plus").frame(width: 22, height: 24).contentShape(Rectangle()) }
            .accessibilityLabel("Zoom in")
            .accessibilityIdentifier("agent-tree-zoom-in")
            .disabled(transform.scale >= AgentTreeTransform.maximumZoom)
        }
        .buttonStyle(.plain)
        .font(TFFont.caption)
        .foregroundStyle(TFColor.textSecondary)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .disabled(!isActive)
        .overlay(alignment: .top) { Rectangle().fill(TFColor.borderDefault).frame(height: 0.5) }
    }

    private func pannableDiagram(_ plan: AgentTreeGeometry.Plan, viewport: CGSize, bounds: CGRect, transform: AgentTreeTransform) -> some View {
        ZStack(alignment: .topLeading) {
            TFColor.bgCanvas
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard isActive else { return }
                        if dragStart == nil { dragStart = currentTransform(content: bounds, viewport: viewport) }
                        applyManual((dragStart ?? transform).panned(by: value.translation, content: bounds, viewport: viewport))
                    }
                    .onEnded { _ in dragStart = nil })
            diagram(plan)
                .frame(width: max(720, viewport.width), height: plan.height, alignment: .topLeading)
                .scaleEffect(transform.scale, anchor: .topLeading)
                .offset(transform.offset)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .clipped()
        .background {
            AgentTreeScrollInput(enabled: isActive, onScroll: { delta in
                guard delta != .zero else { return }
                applyManual(currentTransform(content: bounds, viewport: viewport).panned(by: delta, content: bounds, viewport: viewport))
            }, onMagnify: { increment, anchor in
                let current = currentTransform(content: bounds, viewport: viewport)
                applyManual(current.zoomed(to: current.scale * (1 + increment), anchor: anchor, content: bounds, viewport: viewport))
            }, onFit: { fitMode = true; dragStart = nil })
            .allowsHitTesting(false)
        }
        .help("Two-finger scroll to pan. Pinch to zoom. Double-tap with two fingers to fit.")
        .onChange(of: viewport) { _, size in
            if !fitMode { manualTransform = manualTransform.panned(by: .zero, content: bounds, viewport: size) }
        }
        .onChange(of: bounds) { _, content in
            if !fitMode { manualTransform = manualTransform.panned(by: .zero, content: content, viewport: viewport) }
        }
        .onChange(of: keyboardFocus) { _, id in
            guard !fitMode, let id, let rect = id == Self.rootID ? plan.root : plan.nodes.first(where: { $0.id == id })?.rect else { return }
            let revealed = transform.revealing(rect, content: bounds, viewport: viewport)
            if revealed != transform { applyManual(revealed) }
        }
    }

    private func diagram(_ plan: AgentTreeGeometry.Plan) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let highlighted = ancestors(of: hoveredID ?? keyboardFocus ?? selectedID, in: plan)
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for node in plan.nodes {
                    let points = AgentTreeGeometry.connection(node, in: plan)
                    var path = Path()
                    if let start = points.first { path.move(to: start) }
                    for index in 1..<points.count {
                        let corner = points[index]
                        guard index + 1 < points.count else { path.addLine(to: corner); continue }
                        let before = points[index - 1], after = points[index + 1]
                        let incoming = hypot(corner.x - before.x, corner.y - before.y)
                        let outgoing = hypot(after.x - corner.x, after.y - corner.y)
                        let radius = min(6, incoming / 2, outgoing / 2)
                        let entry = CGPoint(x: corner.x + (before.x - corner.x) * radius / incoming, y: corner.y + (before.y - corner.y) * radius / incoming)
                        let exit = CGPoint(x: corner.x + (after.x - corner.x) * radius / outgoing, y: corner.y + (after.y - corner.y) * radius / outgoing)
                        path.addLine(to: entry)
                        path.addQuadCurve(to: exit, control: corner)
                    }
                    let end = points.last ?? .zero
                    let active = highlighted.contains(node.id)
                    context.stroke(path, with: .color(TFColor.borderAccent.opacity(active ? 0.95 : 0.42)), style: StrokeStyle(lineWidth: active ? 1.5 : 1, lineCap: .round, lineJoin: .round))
                    let port = CGRect(x: end.x - 2, y: end.y - 2, width: 4, height: 4)
                    context.fill(Path(ellipseIn: port), with: .color(TFColor.bgElevated))
                    context.stroke(Path(ellipseIn: port), with: .color(TFColor.borderAccent.opacity(0.6)), lineWidth: 0.75)
                }
            }.accessibilityHidden(true).allowsHitTesting(false)
            card(id: Self.rootID, title: root.title, kind: "Main", status: root.status, elapsed: root.elapsed,
                 summary: rootSummary,
                 hasChildren: !rows.isEmpty, expanded: rootExpanded, rect: plan.root,
                 open: { onOpen(nil) }, toggle: { rootExpanded.toggle() })
            ForEach(plan.nodes) { node in
                if let row = byID[node.id] {
                    card(id: row.id, title: row.task.title, kind: row.task.kind.word,
                         status: row.task.statusUnknown ? nil : row.task.status,
                         elapsed: elapsed(row.task), summary: row.branchSummary,
                         hasChildren: row.hasChildren, expanded: row.isExpanded, rect: node.rect,
                         open: { onOpen(row.id) }, toggle: { onToggle(row) })
                }
            }
        }
    }

    private func ancestors(of id: String?, in plan: AgentTreeGeometry.Plan) -> Set<String> {
        let parents = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0.parent) })
        var result: Set<String> = []
        var cursor = id
        while let current = cursor, result.insert(current).inserted { cursor = parents[current] }
        return result
    }

    private func elapsed(_ task: TaskforceKit.BackgroundTask) -> String? {
        guard !task.statusUnknown else { return nil }
        if task.status == .running, let started = task.startedAt { return SessionTime.clock(now.timeIntervalSince(started)) }
        return task.duration.map(SessionTime.worked)
    }

    private func card(id: String, title: String, kind: String, status: BackgroundTaskStatus?, elapsed: String?, summary: String?,
                      hasChildren: Bool, expanded: Bool, rect: CGRect, open: @escaping () -> Void, toggle: @escaping () -> Void) -> some View {
        let active = keyboardFocus == id || selectedID == id
        let hovered = hoveredID == id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                focusedID = id
                open()
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        AgentMark(root.agent, size: 16).accessibilityHidden(true)
                        Text(kind).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        if let status { badge(status) }
                    }
                    Text(title).font(.system(size: 14)).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(TFColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($keyboardFocus, equals: id)
            .accessibilityLabel([kind, title, status?.word, summary].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Open conversation")
            .accessibilityIdentifier("agent-card-\(id)")
            .accessibilityAddTraits(selectedID == id ? .isSelected : [])
            Spacer(minLength: 4)
            if let summary {
                Text(summary).font(.system(size: 10)).foregroundStyle(TFColor.textSecondary).lineLimit(1)
            }
            HStack(spacing: 4) {
                if let elapsed {
                    Image(systemName: "clock").font(.system(size: 9)).accessibilityHidden(true)
                    Text(elapsed).monospacedDigit()
                }
                Spacer(minLength: 0)
                if hasChildren {
                    Button(action: toggle) {
                        HStack(spacing: 4) {
                            Text(expanded ? "Sub-agents" : "Show sub-agents")
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).rotationEffect(.degrees(expanded ? 0 : -90))
                        }
                        .padding(.vertical, 2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(expanded ? "Collapse" : "Expand") sub-agents of \(title)")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                }
            }
            .font(.system(size: 10)).foregroundStyle(TFColor.textSecondary)
        }
        .padding(10)
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .background(TFColor.bgElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(active ? TFColor.borderAccent : hovered ? TFColor.borderAccent.opacity(0.4) : TFColor.borderDefault, lineWidth: active ? 1.25 : 0.5) }
        // A drag beginning on a card is neither a selection nor a canvas pan.
        // The competing gesture cancels button activation after the movement threshold.
        .highPriorityGesture(DragGesture(minimumDistance: 4).onChanged { _ in })
        .onHover { hovering in hoveredID = hovering ? id : (hoveredID == id ? nil : hoveredID) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: active)
        .offset(x: rect.minX, y: rect.minY)
    }

    private func badge(_ status: BackgroundTaskStatus) -> some View {
        let color: Color = switch status {
        case .running: TFColor.textLink
        case .done: TFColor.textPrimary
        case .failed: TFColor.statusOverdue
        case .stopped: TFColor.textSecondary
        }
        let symbol = switch status {
        case .running: "circle.dotted"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .stopped: "stop.circle"
        }
        return HStack(spacing: 3) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(status.word)
        }
        .font(.system(size: 9))
        .foregroundStyle(color)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        .fixedSize()
    }
}
#endif
