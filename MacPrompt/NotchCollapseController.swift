import AppKit
import Combine
import Foundation

/// Manages the "hide into notch" idle-collapse behavior for the PromptMe overlay panel.
///
/// **States**: `.expanded` → `.collapsing` → `.collapsed` → `.expanding` → `.expanded`
///
/// When the mouse leaves the panel area, an idle timer fires after `idleDelay` seconds
/// and smoothly retracts the overlay into the MacBook notch (or top-center edge on
/// displays without a notch), leaving a small intentional peek lip visible. Moving the
/// cursor back over the notch/peek region immediately expands the overlay.
///
/// ## Notch & Safe-Area Positioning
///
/// On modern MacBooks with a hardware notch, `NSScreen` exposes:
/// - `safeAreaInsets.top` — height of the reserved top safe area (the physical notch).
/// - `auxiliaryTopLeftArea` & `auxiliaryTopRightArea` — the unobstructed menu-bar regions
///   to the left and right of the notch, in global screen coordinates.
///
/// Using those values, we compute the physical notch's horizontal span, center X, and
/// bottom Y (`screen.frame.maxY - notchHeight`). When collapsed, the overlay retracts
/// into that notch span while extending `peekHeight` (10 pt) below `notchBottomY` so the
/// rounded bottom lip and subtle indicator remain clearly visible and easy to hover over.
///
/// On displays without a notch (`safeAreaInsets.top == 0` and no auxiliary top areas),
/// it falls back to a compact centered top-edge notch tab extending `peekHeight` (10 pt)
/// below `screen.frame.maxY`.
@MainActor
final class NotchCollapseController: ObservableObject {

    // MARK: - State & Presentation

    enum CollapseState {
        case expanded
        case collapsing
        case collapsed
        case expanding
    }

    struct Presentation: Equatable {
        var isCollapsed: Bool = false
        var collapsedWidth: CGFloat = 216
        var collapsedHeight: CGFloat = 48
        var notchOffsetX: CGFloat = 0
    }

    struct NotchGeometry: Equatable {
        let hasNotch: Bool
        let centerX: CGFloat
        let notchWidth: CGFloat
        let notchHeight: CGFloat
        let notchBottomY: CGFloat
    }

    @Published private(set) var presentation = Presentation()
    private(set) var state: CollapseState = .expanded

    // MARK: - Configuration

    /// Seconds of mouse-away idleness before auto-collapsing.
    static let idleDelay: TimeInterval = 1.5
    /// Visible height (pt) below the physical notch (or screen top on non-notch displays).
    /// 10 pt keeps the collapsed notch lip ultra-subtle while remaining easy to hover.
    static let peekHeight: CGFloat = 10
    /// Expand/collapse animation duration in seconds.
    static let animationDuration: TimeInterval = 0.30

    private static let fallbackNotchWidth: CGFloat = 200
    private static let nonNotchCollapsedWidth: CGFloat = 180
    private static let notchShoulderPadding: CGFloat = 20

    // MARK: - Dependencies

    private weak var panel: NSPanel?
    private var screenProvider: (() -> NSScreen?)?
    private var expandedFrameProvider: (() -> NSRect)?

    // MARK: - Internal Tracking

    private var idleTimer: Timer?
    private var animationToken: UInt64 = 0
    private var expandedFrame: NSRect = .zero
    private var currentNotchGeometry: NotchGeometry?
    private var isPromptRunning: Bool = false
    private var playbackCancellable: AnyCancellable?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    // MARK: - Init / Attach

    init() {}

    func attach(
        panel: NSPanel,
        model: PrompterModel,
        screenProvider: @escaping () -> NSScreen?,
        expandedFrameProvider: @escaping () -> NSRect
    ) {
        self.panel = panel
        self.screenProvider = screenProvider
        self.expandedFrameProvider = expandedFrameProvider
        self.isPromptRunning = model.isRunning || model.isCountingDown
        refreshGeometry()
        observePlaybackState(model: model)
        installMouseMonitorsIfNeeded()
    }

    deinit {
        idleTimer?.invalidate()
        playbackCancellable?.cancel()
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
    }

    // MARK: - Public Lifecycle Hooks

    /// Call whenever the panel is repositioned, resized, or moved between displays.
    func panelDidReposition() {
        refreshGeometry()
    }

    /// Call when the overlay becomes visible.
    func overlayDidShow() {
        animationToken &+= 1
        cancelIdleTimer()
        state = .expanded
        panel?.ignoresMouseEvents = false
        refreshGeometry()
        if presentation.isCollapsed {
            presentation.isCollapsed = false
        }
    }

    /// Call when the overlay is hidden.
    func overlayDidHide() {
        animationToken &+= 1
        cancelIdleTimer()
        state = .expanded
        panel?.ignoresMouseEvents = false
        if presentation.isCollapsed {
            presentation.isCollapsed = false
        }
    }

    // MARK: - Notch Geometry

    private func refreshGeometry() {
        let nextExpandedFrame = expandedFrameProvider?() ?? panel?.frame ?? .zero
        expandedFrame = nextExpandedFrame

        guard let screen = screenProvider?() ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let geometry = Self.computeNotchGeometry(for: screen)
        currentNotchGeometry = geometry

        let targetCollapsedWidth: CGFloat
        if geometry.hasNotch {
            targetCollapsedWidth = min(
                max(nextExpandedFrame.width, 1),
                geometry.notchWidth + Self.notchShoulderPadding
            )
        } else {
            targetCollapsedWidth = min(
                max(nextExpandedFrame.width, 1),
                Self.nonNotchCollapsedWidth
            )
        }

        let targetCollapsedHeight = min(
            max(nextExpandedFrame.height, Self.peekHeight),
            geometry.notchHeight + Self.peekHeight
        )
        let offsetX = (geometry.centerX - nextExpandedFrame.midX).rounded()

        let updated = Presentation(
            isCollapsed: presentation.isCollapsed,
            collapsedWidth: targetCollapsedWidth.rounded(),
            collapsedHeight: targetCollapsedHeight.rounded(),
            notchOffsetX: offsetX
        )

        if presentation != updated {
            presentation = updated
        }
    }

    static func computeNotchGeometry(for screen: NSScreen) -> NotchGeometry {
        let safeTop = max(0, screen.safeAreaInsets.top)
        let topLeft = screen.auxiliaryTopLeftArea
        let topRight = screen.auxiliaryTopRightArea

        let hasAuxiliaryAreas: Bool = {
            guard let left = topLeft, let right = topRight else { return false }
            return !left.isEmpty && !right.isEmpty && right.minX > left.maxX
        }()

        if safeTop > 0 || hasAuxiliaryAreas {
            let auxiliaryHeight = max(topLeft?.height ?? 0, topRight?.height ?? 0)
            let notchHeight = safeTop > 0 ? safeTop : auxiliaryHeight

            let notchWidth: CGFloat
            let centerX: CGFloat
            if let left = topLeft, let right = topRight, right.minX > left.maxX {
                notchWidth = right.minX - left.maxX
                centerX = (left.maxX + right.minX) / 2
            } else {
                notchWidth = fallbackNotchWidth
                centerX = screen.frame.midX
            }

            return NotchGeometry(
                hasNotch: true,
                centerX: centerX,
                notchWidth: notchWidth,
                notchHeight: notchHeight,
                notchBottomY: screen.frame.maxY - notchHeight
            )
        }

        return NotchGeometry(
            hasNotch: false,
            centerX: screen.frame.midX,
            notchWidth: nonNotchCollapsedWidth,
            notchHeight: 0,
            notchBottomY: screen.frame.maxY
        )
    }

    // MARK: - Playback State Observation

    private func observePlaybackState(model: PrompterModel) {
        playbackCancellable?.cancel()
        playbackCancellable = Publishers.CombineLatest(
            model.$isRunning.removeDuplicates(),
            model.$isCountingDown.removeDuplicates()
        )
        .map { isRunning, isCountingDown in
            isRunning || isCountingDown
        }
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] isActive in
            self?.handlePlaybackStateChanged(isActive: isActive)
        }
    }

    private func handlePlaybackStateChanged(isActive: Bool) {
        isPromptRunning = isActive
        if isActive {
            cancelIdleTimer()
            if state == .collapsed || state == .collapsing {
                animateToExpanded()
            }
        } else {
            evaluateMousePosition()
        }
    }

    // MARK: - Mouse Monitoring

    private func installMouseMonitorsIfNeeded() {
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
            ) { [weak self] _ in
                Task { @MainActor in self?.evaluateMousePosition() }
            }
        }

        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .scrollWheel]
            ) { [weak self] event in
                Task { @MainActor in self?.evaluateMousePosition() }
                return event
            }
        }
    }

    private func evaluateMousePosition() {
        guard let panel, panel.isVisible else { return }

        if isPromptRunning {
            cancelIdleTimer()
            if state == .collapsed || state == .collapsing {
                animateToExpanded()
            }
            return
        }

        let mouseLocation = NSEvent.mouseLocation

        switch state {
        case .expanded:
            if expandedHitTest(mouseLocation) {
                cancelIdleTimer()
            } else {
                startIdleTimerIfNeeded()
            }

        case .collapsing:
            if expandedHitTest(mouseLocation) || peekHitTest(mouseLocation) {
                cancelIdleTimer()
                animateToExpanded()
            }

        case .collapsed:
            if peekHitTest(mouseLocation) {
                cancelIdleTimer()
                animateToExpanded()
            }

        case .expanding:
            if expandedHitTest(mouseLocation) || peekHitTest(mouseLocation) {
                cancelIdleTimer()
            }
        }
    }

    // MARK: - Hit Testing

    private func expandedHitTest(_ point: NSPoint) -> Bool {
        let hitRect = expandedFrame.insetBy(dx: -6, dy: -8)
        return hitRect.contains(point)
    }

    private func peekHitTest(_ point: NSPoint) -> Bool {
        guard let screen = screenProvider?() ?? NSScreen.main ?? NSScreen.screens.first else {
            return false
        }

        let geometry = currentNotchGeometry ?? Self.computeNotchGeometry(for: screen)
        let width = presentation.collapsedWidth
        let x = geometry.centerX - (width / 2)
        let minY = geometry.notchBottomY - Self.peekHeight
        let height = max(Self.peekHeight, screen.frame.maxY - minY)

        // Covers the physical notch + visible peek lip, with generous margins
        // so moving onto the lip or notch area reliably expands the overlay.
        let peekRect = NSRect(x: x, y: minY, width: width, height: height)
        let hitRect = peekRect.insetBy(dx: -16, dy: -10)
        return hitRect.contains(point)
    }

    // MARK: - Idle Timer

    private func startIdleTimerIfNeeded() {
        guard !isPromptRunning, idleTimer == nil, state == .expanded else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.idleTimerFired()
            }
        }
    }

    private func cancelIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func idleTimerFired() {
        idleTimer = nil
        guard !isPromptRunning, state == .expanded else { return }

        let mouseLocation = NSEvent.mouseLocation
        if expandedHitTest(mouseLocation) {
            return
        }

        animateToCollapsed()
    }

    // MARK: - Transitions

    private func animateToCollapsed() {
        guard let panel, panel.isVisible else { return }
        guard !isPromptRunning, state == .expanded else { return }

        refreshGeometry()
        state = .collapsing
        animationToken &+= 1
        let token = animationToken

        presentation.isCollapsed = true

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationDuration) { [weak self] in
            guard let self, self.animationToken == token, self.state == .collapsing else { return }
            self.state = .collapsed
            self.panel?.ignoresMouseEvents = true
            // Re-check cursor in case it moved onto the peek area right as collapse finished.
            self.evaluateMousePosition()
        }
    }

    private func animateToExpanded() {
        guard let panel else { return }
        guard state == .collapsed || state == .collapsing else { return }

        refreshGeometry()
        state = .expanding
        animationToken &+= 1
        let token = animationToken

        panel.ignoresMouseEvents = false
        presentation.isCollapsed = false

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationDuration) { [weak self] in
            guard let self, self.animationToken == token, self.state == .expanding else { return }
            self.state = .expanded
            self.evaluateMousePosition()
        }
    }
}
