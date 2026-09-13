import AppKit
import Combine
import Foundation
import SwiftUI

/// A single, coalesced request to position the conversation viewport.
///
/// Bumping `revision` re-runs the conversation's `.task(id:)`, so several
/// requests produced inside one SwiftUI update collapse into one
/// `ScrollViewReader.scrollTo`.
struct ConversationScrollRequest: Equatable {
    enum Reason: String, Equatable {
        /// A saved conversation finished restoring.
        case restored
        /// The active Run reached a terminal state (or detached).
        case runTerminal
        /// Content grew or was re-projected while we were following the bottom.
        case contentGrew
        /// The user asked for the bottom (button, composer submit).
        case userRequested
        /// A historical turn was picked from the turn menu; position at its top.
        case turnSelected
        /// A new round started; show it from its beginning (the user's question).
        case newTurn
    }

    /// Which end of the content the viewport should land on.
    enum Anchor: String, Equatable {
        case top
        case bottom
    }

    var revision = 0
    var reason: Reason = .contentGrew
    var anchor: Anchor = .bottom
    var animated = false
}

/// The only place that decides whether the conversation should sit at its
/// bottom.
///
/// It owns no AppKit state: geometry samples and content revisions come in, and
/// a scroll request plus the flags the UI needs go out. The view turns the
/// request into SwiftUI's own `ScrollViewReader.scrollTo`, so SwiftUI keeps full
/// ownership of the viewport. See `SCROLL_DESIGN.md`.
@MainActor
final class ConversationScrollModel: ObservableObject {
    /// Distance from the document bottom that still counts as “at the bottom”.
    static let bottomThreshold: CGFloat = 60

    /// Geometry-derived; drives the “back to bottom” button.
    @Published private(set) var atBottom = true
    /// User intent. Cleared only when the *user* moves the viewport away from
    /// the bottom (never merely because the document grew), and restored when
    /// they come back or explicitly ask for the bottom. This single flag
    /// replaces the scattered `isLoading` / `wasAtBottomBeforeReview` /
    /// `distanceToBottom() <= 50` checks.
    @Published private(set) var followBottom = true
    /// The coalesced positioning request.
    @Published private(set) var request = ConversationScrollRequest()
    /// True while a saved conversation is being restored: geometry and content
    /// growth must neither flip `followBottom` nor issue a request.
    private(set) var isSuppressed = false

    /// The laid-out height of the conversation content, reported by the view
    /// after every layout pass.
    private var contentHeight: CGFloat = 0
    /// Consecutive height-driven bottom re-anchors still allowed. A layout that
    /// keeps changing is chased while the allowance lasts; the moment a layout
    /// pass reports an unchanged height the allowance is refilled, so a block
    /// that arrives later (a change card fetched over the network, an image that
    /// finished decoding) is still followed while a runaway scroll ↔ layout
    /// feedback loop cannot spin forever.
    private var settleBudget = ConversationScrollModel.settleReanchorLimit
    private static let settleReanchorLimit = 40
    /// macOS 15+ (`onScrollPhaseChange`): true while the user drives the scroll.
    private var isUserScrolling = false

    // MARK: - Lifecycle

    /// A different session starts loading: forget the previous conversation's
    /// intent and wait for the restore to finish before positioning again.
    func beginConversationReset() {
        isSuppressed = true
        followBottom = true
        atBottom = true
        contentHeight = 0
        settleBudget = Self.settleReanchorLimit
    }

    /// The restore committed its content: open it at the top of its newest turn
    /// and stop tracking the bottom.
    ///
    /// Every entry into a turn reads from its beginning (a new round, a
    /// historical turn, “back to the latest turn”, and a restored conversation),
    /// so this is deliberately *not* gated by the follow intent — a restore has
    /// no user intent yet — and it does not enable following. The user re-enters
    /// follow mode with the round button or by scrolling to the bottom.
    func openRestoredConversationAtTop() {
        isSuppressed = false
        followBottom = false
        contentHeight = 0
        enqueue(.restored, anchor: .top, animated: false)
    }

    // MARK: - Geometry inputs

    /// macOS 15+ (`onScrollGeometryChange`): the derived “at bottom” flag.
    /// The transform publishes a `Bool`, so this only fires on threshold
    /// crossings instead of on every scrolled point.
    func reportAtBottom(_ value: Bool) {
        guard value != atBottom else { return }
        atBottom = value
        guard !isSuppressed else { return }
        // Only a *user* move changes the follow intent. A reading produced by
        // the layout — a turn that is shorter than the viewport, or growth that
        // has not exceeded it yet — must never re-enable following behind the
        // user's back (a new round is opened at its top and has to stay there).
        if isUserScrolling { followBottom = value }
    }

    /// macOS 14 fallback: raw geometry from the read-only probe, which is also
    /// the only source of the content height on that OS. An offset move with a
    /// *stable* content height is a user scroll; a move that came with a height
    /// change is ours.
    func reportGeometry(contentHeight: CGFloat, offsetY: CGFloat, viewportHeight: CGFloat) {
        let previousHeight = self.contentHeight
        let value = contentHeight - offsetY - viewportHeight <= Self.bottomThreshold
        if value != atBottom {
            atBottom = value
            // macOS 14 has no scroll-phase signal, so a reading with a *stable*
            // content height is the only evidence that the user (not the layout)
            // moved the viewport.
            if !isSuppressed, isUserScrolling || abs(contentHeight - previousHeight) <= 0.5 {
                followBottom = value
            }
        }
        reportContentHeight(contentHeight)
    }

    /// The conversation content was laid out at `height`.
    ///
    /// Every block that changes the document height reports through here — text
    /// reflow, Markdown, file preview strips, change cards, artifact cards,
    /// images — so the final scroll position is decided from the **real laid-out
    /// height** instead of from a frame count or a timer. While following, each
    /// height change re-anchors the bottom (coalesced to one `scrollTo` per
    /// update by the view's `.task(id:)`) until the height stops changing, which
    /// is when the layout is complete and the position is final.
    func reportContentHeight(_ height: CGFloat) {
        guard abs(height - contentHeight) > 0.5 else {
            // Stable across a layout pass: the layout is complete, so refill the
            // allowance for any block that is still on its way.
            settleBudget = Self.settleReanchorLimit
            return
        }
        contentHeight = height
        guard followBottom, !isSuppressed, settleBudget > 0 else { return }
        settleBudget -= 1
        enqueue(.contentGrew, anchor: .bottom, animated: false)
    }

    /// macOS 15+ (`onScrollPhaseChange`): whether the user is driving the scroll.
    func reportUserScrolling(_ scrolling: Bool) {
        guard scrolling != isUserScrolling else { return }
        isUserScrolling = scrolling
        // Grabbing the viewport away from the bottom stops the follow right
        // away, before the next streamed chunk could pull it back.
        if scrolling, !atBottom, !isSuppressed {
            followBottom = false
        }
    }

    // MARK: - Intents

    /// The transcript changed (streamed chunk, new turn, turn body committed).
    func contentDidChange(animated: Bool) {
        guard followBottom, !isSuppressed else { return }
        enqueue(.contentGrew, anchor: .bottom, animated: animated)
    }

    /// A structural jump: the restore finished, or the Run reached a terminal
    /// state. Only fires while the user is still following the bottom.
    func requireJump(
        _ reason: ConversationScrollRequest.Reason,
        anchor: ConversationScrollRequest.Anchor = .bottom,
        animated: Bool = false,
        force: Bool = false
    ) {
        if force { followBottom = true }
        guard followBottom, !isSuppressed else { return }
        enqueue(reason, anchor: anchor, animated: animated)
    }

    /// The user explicitly asked for the bottom (button, composer submit, turn
    /// menu picking the newest turn).
    func pinToBottom(animated: Bool = true) {
        followBottom = true
        atBottom = true
        isSuppressed = false
        enqueue(.userRequested, anchor: .bottom, animated: animated)
    }

    /// Show the selected turn from its beginning — a historical turn *and* the
    /// newest turn reached through "back to the latest turn", which opens
    /// exactly like a newly started round. Tracking the bottom stops until the
    /// user asks for it again (the round button, or scrolling to the bottom).
    func showTurnFromTop() {
        isSuppressed = false
        followBottom = false
        enqueue(.turnSelected, anchor: .top, animated: false)
    }

    /// A new round started: open it at its top (the user's question) and stop
    /// following until the user asks for the bottom again (the round button, or
    /// scrolling to the bottom themselves).
    func startNewTurnFromTop() {
        isSuppressed = false
        followBottom = false
        enqueue(.newTurn, anchor: .top, animated: false)
    }

    // MARK: - Private

    private func enqueue(
        _ reason: ConversationScrollRequest.Reason,
        anchor: ConversationScrollRequest.Anchor,
        animated: Bool
    ) {
        request = ConversationScrollRequest(revision: request.revision &+ 1, reason: reason, anchor: anchor, animated: animated)
        // Metadata only: no transcript text, no user content.
        RuntimeLog.shared.write(
            "scroll",
            "request reason=\(reason.rawValue) anchor=\(anchor.rawValue) revision=\(request.revision) animated=\(animated) followBottom=\(followBottom) atBottom=\(atBottom)"
        )
    }
}

// MARK: - macOS 14 geometry probe

/// Reports the conversation's scroll geometry on macOS 14, where
/// `onScrollGeometryChange` (macOS 15+) is unavailable.
///
/// It is strictly **read-only**: it never moves the clip view, so SwiftUI keeps
/// full ownership of the viewport. Positioning always goes through
/// `ScrollViewReader.scrollTo`.
struct ConversationVisibilityObserver: NSViewRepresentable {
    /// contentHeight, clip origin y, clip height — in the hosting document's
    /// (flipped) coordinate space.
    let onGeometry: (CGFloat, CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onGeometry: onGeometry)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.postsFrameChangedNotifications = false
        context.coordinator.onGeometry = onGeometry
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onGeometry = onGeometry
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator {
        var onGeometry: (CGFloat, CGFloat, CGFloat) -> Void
        weak var anchorView: NSView?
        weak var observedScrollView: NSScrollView?
        weak var observedDocumentView: NSView?
        var boundsObserver: NSObjectProtocol?
        var documentFrameObserver: NSObjectProtocol?
        /// Bounds/frame notifications arrive far faster than SwiftUI can use
        /// them; publish at most once per main-queue turn.
        private var reportScheduled = false

        init(onGeometry: @escaping (CGFloat, CGFloat, CGFloat) -> Void) {
            self.onGeometry = onGeometry
        }

        func attach(to view: NSView) {
            anchorView = view
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view,
                      let scrollView = Self.findScrollView(from: view) else { return }
                self.observe(scrollView)
                self.report()
            }
        }

        private func observe(_ scrollView: NSScrollView) {
            let documentView = scrollView.documentView
            guard observedScrollView !== scrollView || observedDocumentView !== documentView else { return }
            detachObservers()
            observedScrollView = scrollView
            observedDocumentView = documentView
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleReport()
            }
            if let documentView {
                documentView.postsFrameChangedNotifications = true
                documentFrameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: documentView,
                    queue: .main
                ) { [weak self] _ in
                    self?.scheduleReport()
                }
            }
        }

        private func scheduleReport() {
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                self.report()
            }
        }

        private func report() {
            guard let scrollView = observedScrollView,
                  let documentView = scrollView.documentView else { return }
            onGeometry(
                documentView.bounds.height,
                scrollView.contentView.bounds.origin.y,
                scrollView.contentView.bounds.height
            )
        }

        private func detachObservers() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let documentFrameObserver { NotificationCenter.default.removeObserver(documentFrameObserver) }
            boundsObserver = nil
            documentFrameObserver = nil
        }

        static func findScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view
            while let candidate = current {
                if let scrollView = candidate as? NSScrollView { return scrollView }
                current = candidate.superview
            }
            return nil
        }

        deinit {
            detachObservers()
        }
    }
}

// MARK: - Observation modifiers

extension View {
    /// Feeds conversation scroll geometry into the model.
    ///
    /// macOS 15+ uses SwiftUI's own reporting: the transform publishes a `Bool`
    /// so the action runs only when the “at the bottom” state crosses the
    /// threshold, and the scroll phase tells a user drag apart from our own
    /// programmatic moves. macOS 14 falls back to a read-only AppKit probe.
    @ViewBuilder
    func conversationScrollObservation(_ model: ConversationScrollModel) -> some View {
        if #available(macOS 15.0, *) {
            self
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
                        <= ConversationScrollModel.bottomThreshold
                } action: { _, atBottom in
                    model.reportAtBottom(atBottom)
                }
                .onScrollPhaseChange { _, phase in
                    model.reportUserScrolling(
                        phase == .interacting || phase == .decelerating || phase == .tracking
                    )
                }
        } else {
            background(
                ConversationVisibilityObserver { contentHeight, offsetY, viewportHeight in
                    model.reportGeometry(
                        contentHeight: contentHeight,
                        offsetY: offsetY,
                        viewportHeight: viewportHeight
                    )
                }
            )
        }
    }

    /// Reports the conversation content's laid-out height.
    ///
    /// Attach to the scroll view's **content** (the `LazyVStack`), so every block
    /// whose size the layout decides — the turn body, Markdown, file preview
    /// strips, change cards, artifact cards, images — is included in the
    /// measurement the final scroll position is derived from. macOS 14 relies on
    /// the read-only scroll probe's document height instead.
    @ViewBuilder
    func conversationContentHeight(_ model: ConversationScrollModel) -> some View {
        if #available(macOS 15.0, *) {
            onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { _, height in
                model.reportContentHeight(height)
            }
        } else {
            self
        }
    }
}

extension View {
    /// Anchors the conversation's first paint to the **top** — a turn is always
    /// read from its beginning (see `openRestoredConversationAtTop`).
    ///
    /// On macOS 15+, `pinOnSizeChanges` additionally keeps the **bottom** pinned
    /// while streamed content grows. It must be off unless the user is actually
    /// following the live conversation, otherwise growth would yank the viewport
    /// away from the top the user is reading.
    @ViewBuilder
    func conversationScrollAnchoring(pinOnSizeChanges: Bool) -> some View {
        if #available(macOS 15.0, *) {
            self
                .defaultScrollAnchor(.top, for: .initialOffset)
                .defaultScrollAnchor(pinOnSizeChanges ? .bottom : nil, for: .sizeChanges)
        } else {
            defaultScrollAnchor(.top)
        }
    }
}
