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
    }

    var revision = 0
    var reason: Reason = .contentGrew
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

    /// macOS 14 fallback: last reported content height, used to tell a
    /// content-size change apart from a pure offset move.
    private var reportedContentHeight: CGFloat = 0
    /// macOS 15+ (`onScrollPhaseChange`): true while the user drives the scroll.
    private var isUserScrolling = false

    // MARK: - Lifecycle

    /// A different session starts loading: forget the previous conversation's
    /// intent and wait for the restore to finish before positioning again.
    func beginConversationReset() {
        isSuppressed = true
        followBottom = true
        atBottom = true
        reportedContentHeight = 0
    }

    /// The restore committed its content; positioning may resume. The caller
    /// issues the single post-restore jump right after this.
    func endConversationReset() {
        isSuppressed = false
        followBottom = true
        reportedContentHeight = 0
    }

    // MARK: - Geometry inputs

    /// macOS 15+ (`onScrollGeometryChange`): the derived “at bottom” flag.
    /// The transform publishes a `Bool`, so this only fires on threshold
    /// crossings instead of on every scrolled point.
    func reportAtBottom(_ value: Bool) {
        guard value != atBottom else { return }
        atBottom = value
        guard !isSuppressed else { return }
        if isUserScrolling {
            followBottom = value
        } else if value {
            // Reaching the bottom always re-pins.
            followBottom = true
        }
        // A flip caused by document growth while the user is idle is ours: it
        // must not stop the follow (the next content change re-pins instead).
    }

    /// macOS 14 fallback: raw geometry from the read-only probe. An offset move
    /// with a *stable* content height is a user scroll; a move that came with a
    /// height change is ours.
    func reportGeometry(contentHeight: CGFloat, offsetY: CGFloat, viewportHeight: CGFloat) {
        let contentChanged = abs(contentHeight - reportedContentHeight) > 0.5
        reportedContentHeight = contentHeight
        let value = contentHeight - offsetY - viewportHeight <= Self.bottomThreshold
        guard value != atBottom else { return }
        atBottom = value
        guard !isSuppressed else { return }
        if isUserScrolling || !contentChanged {
            followBottom = value
        } else if value {
            followBottom = true
        }
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

    /// The transcript changed (streamed chunk, new turn, expanded content).
    func contentDidChange(animated: Bool) {
        guard followBottom, !isSuppressed else { return }
        enqueue(.contentGrew, animated: animated)
    }

    /// A structural jump: the restore finished, or the Run reached a terminal
    /// state. Only fires while the user is still following the bottom.
    func requireJump(_ reason: ConversationScrollRequest.Reason, animated: Bool = false, force: Bool = false) {
        if force { followBottom = true }
        guard followBottom, !isSuppressed else { return }
        enqueue(reason, animated: animated)
    }

    /// The user explicitly asked for the bottom (button, composer submit).
    func pinToBottom(animated: Bool = true) {
        followBottom = true
        atBottom = true
        isSuppressed = false
        enqueue(.userRequested, animated: animated)
    }

    // MARK: - Private

    private func enqueue(_ reason: ConversationScrollRequest.Reason, animated: Bool) {
        request = ConversationScrollRequest(revision: request.revision &+ 1, reason: reason, animated: animated)
        // Metadata only: no transcript text, no user content.
        RuntimeLog.shared.write(
            "scroll",
            "request reason=\(reason.rawValue) revision=\(request.revision) animated=\(animated) followBottom=\(followBottom) atBottom=\(atBottom)"
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
}

extension View {
    /// Anchors the conversation to its bottom.
    ///
    /// `initialOffset` makes the first paint land at the bottom, so a restored
    /// or switched conversation never opens off-screen; on macOS 15+
    /// `sizeChanges` keeps it pinned while streamed content grows. Together they
    /// replace the old “settle for N frames / retry for 4 seconds” heuristics.
    @ViewBuilder
    func conversationBottomAnchoring() -> some View {
        if #available(macOS 15.0, *) {
            self
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            defaultScrollAnchor(.bottom)
        }
    }
}
