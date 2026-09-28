import AppKit

/// A terminal window style that provides a transparent titlebar effect. With this effect, the titlebar
/// matches the background color of the window.
class TransparentTitlebarTerminalWindow: TerminalWindow {
    /// Stores the last surface configuration to reapply appearance when needed.
    /// This is necessary because various macOS operations (tab switching, tab bar
    /// visibility changes) can reset the titlebar appearance.
    private var lastSurfaceConfig: Ghostty.SurfaceView.DerivedConfig?

    /// KVO observation for tab group window changes.
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupWindowsObservation: NSKeyValueObservation?
    private var tabBarVisibleObservation: NSKeyValueObservation?
    private var tabSelectionObservation: NSKeyValueObservation?

    deinit {
        tabGroupWindowsObservation?.invalidate()
        tabBarVisibleObservation?.invalidate()
        tabSelectionObservation?.invalidate()
    }

    // MARK: NSWindow

    override func awakeFromNib() {
        super.awakeFromNib()

        // Setup all the KVO we will use, see the docs for the respective functions
        // to learn why we need KVO.
        setupKVO()
    }

    override func resignMain() {
        super.resignMain()
        scheduleTabBarStyleSync()
    }

    override func becomeKey() {
        super.becomeKey()
        scheduleTabBarStyleSync()
    }

    override func resignKey() {
        super.resignKey()
        scheduleTabBarStyleSync()
    }

    /// AppKit restyles the native tab bar after key/main transitions and tab
    /// selection changes, undoing our material fixes. Re-apply on the next
    /// runloop turns.
    private func scheduleTabBarStyleSync() {
        syncTabBarStyle()
        DispatchQueue.main.async { [weak self] in self?.syncTabBarStyle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.syncTabBarStyle()
        }
    }

    override func becomeMain() {
        super.becomeMain()
        scheduleTabBarStyleSync()

        guard let lastSurfaceConfig else { return }
        syncAppearance(lastSurfaceConfig)

        // This is a nasty edge case. If we're going from 2 to 1 tab and the tab bar
        // automatically disappears, then we need to resync our appearance because
        // at some point macOS replaces the tab views.
        if tabGroup?.windows.count ?? 0 == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.syncAppearance(self?.lastSurfaceConfig ?? lastSurfaceConfig)
            }
        }
    }

    override func update() {
        super.update()

        // On macOS 13 to 15, we need to hide the NSVisualEffectView in order to allow our
        // titlebar to be truly transparent.
        if #unavailable(macOS 26) {
            if !effectViewIsHidden {
                hideEffectView()
            }
        }

        // Adding a tab rebuilds the tab bar lazily, after our KVO callbacks have
        // already run. This runs once per event loop pass before display, so it is
        // the earliest reliable point to fix the new bar up before it is drawn.
        //
        // Every call walks the titlebar view tree and the tab bar's layer tree,
        // then rewrites the fill and every tint unconditionally. Windows without
        // a tab bar bail out after the first walk.
        syncTabBarStyle()
    }

    // MARK: Appearance

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        // override appearance based on the terminal's background color
        if let preferredBackgroundColor {
            appearance = (preferredBackgroundColor.isLightColor ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua))
        }

        // Save our config in case we need to reapply
        lastSurfaceConfig = surfaceConfig

        // Every time we change appearance, set KVO up again in case any of our
        // references changed (e.g. tabGroup is new).
        setupKVO()

        if #available(macOS 26.0, *) {
            syncAppearanceTahoe(surfaceConfig)
        } else {
            syncAppearanceVentura(surfaceConfig)
        }
    }

    @available(macOS 26.0, *)
    private func syncAppearanceTahoe(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // When we have transparency, we need to set the titlebar background to match the
        // window background but with opacity. The window background is set using the
        // "preferred background color" property.
        //
        // Even if we aren't transparent, we still set this because this becomes the
        // color of the titlebar in native fullscreen view.
        if let titlebarView = titlebarContainer?.firstDescendant(withClassName: "NSTitlebarView") {
            titlebarView.wantsLayer = true

            // For glass background styles, use a transparent titlebar to let the glass effect show through
            // Only apply this for transparent and tabs titlebar styles
            let isGlassStyle = derivedConfig.backgroundBlur.isGlassStyle
            let isTransparentTitlebar = derivedConfig.macosTitlebarStyle == .transparent ||
            derivedConfig.macosTitlebarStyle == .tabs

            titlebarView.layer?.backgroundColor = (isGlassStyle && isTransparentTitlebar)
                ? NSColor.clear.cgColor
                : preferredBackgroundColor?.cgColor
        }

        // In all cases, we have to hide the background view since this has multiple subviews
        // that force a background color.
        titlebarBackgroundView?.isHidden = true

        syncTabBarStyle()
    }

    /// On macOS 27 the native tab bar draws liquid glass that ignores the titlebar
    /// colour, so the strip stays system grey whatever the terminal background is.
    /// This restyles it to look like the flat, squared pre-Tahoe tab bar: the
    /// selected tab matches the terminal and the others sit on a slightly
    /// lighter (or, for light themes, darker) strip.
    ///
    /// The track's grey is a CoreUI material (`kCUIVariantContentBackgroundMaterial`)
    /// whose `fill` sublayer is a fixed grey, composited over a `CABackdropLayer`
    /// blur and then lifted by a vibrancy colour matrix. We repaint that fill and
    /// drop the matrix.
    ///
    /// Only the selected (or hovered) tab's `NSGlassEffectView` actually renders
    /// glass. See `flattenGlass` for how that is reduced to a plain fill.
    ///
    /// Everything is squared off too. The track and each tab's clip use a NaN
    /// corner radius (a capsule derived from the height) and the glass has a 12pt
    /// radius; zeroing both gives flush square segments.
    ///
    /// Safe to call repeatedly; AppKit rebuilds the tab bar often (and restores
    /// the capsule on resize) so this runs from every appearance sync and after
    /// every tab bar layout.
    func syncTabBarStyle() {
        guard #available(macOS 27, *) else { return }
        guard let tabBarView else { return }

        // We're poking raw CALayers, which pick up implicit animations. Without
        // this the recolour fades in over 250ms every time AppKit rebuilds the
        // tab bar, which reads as a flash of grey.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // A glass background style deliberately leaves the titlebar clear so the
        // glass shows through (see syncAppearanceTahoe). Painting an opaque fill
        // into the track would punch a solid block through it, so only square
        // the tab bar in that case.
        let recolor = !(derivedConfig.backgroundBlur.isGlassStyle &&
            (derivedConfig.macosTitlebarStyle == .transparent ||
             derivedConfig.macosTitlebarStyle == .tabs))
        guard recolor, let bg = preferredBackgroundColor else {
            squareTabBar(tabBarView)
            return
        }

        let trackColor = Self.adjust(bg, by: 0.14)
        let hoverColor = Self.adjust(bg, by: 0.22)

        if let root = tabBarView.layer {
            Self.forEachLayer(in: root) { layer in
                Self.squareCorners(of: layer)

                switch layer.name {
                case "NSTabBarTrackVibrantColorMatrix":
                    // Lightens whatever sits beneath it, which drags the recoloured
                    // fill well away from the colour we set.
                    layer.isHidden = true

                case "kCUIVariantContentBackgroundMaterial":
                    for fill in layer.sublayers ?? [] where fill.name == "fill" {
                        fill.backgroundColor = trackColor.cgColor
                    }

                default:
                    break
                }
            }
        }

        let selectedIndex: Int? = tabGroup.flatMap { group in
            group.selectedWindow.flatMap { group.windows.firstIndex(of: $0) }
        }

        // Reuses the tabBarView bound above; tabButtonsInVisualOrder() would walk
        // the titlebar a second time to find the same view.
        //
        // Known limitation: selectedIndex is a position in the model order
        // (`tabGroup.windows`) compared against visual order here. The two can
        // disagree mid-drag or immediately after a tab is added, which briefly
        // paints the wrong button until the next sync corrects it.
        let buttons = tabBarView.descendants(withClassName: "NSTabButton")
            .sorted { $0.frame.minX < $1.frame.minX }
        for (index, button) in buttons.enumerated() {
            // Titles blend through a vibrancy filter keyed off the track matrix we
            // hid, which leaves unselected titles nearly invisible. Without it they
            // draw in plain label / secondary label colours.
            for title in button.descendants(withClassName: "NSTextField")
            where title.layer?.compositingFilter != nil {
                title.layer?.compositingFilter = nil
            }

            guard let glass = button.firstDescendant(withClassName: "NSGlassEffectView")
                    as? NSGlassEffectView else { continue }
            if glass.cornerRadius != 0 { glass.cornerRadius = 0 }
            Self.flattenGlass(glass, fill: index == selectedIndex ? bg : hoverColor)
        }
    }

    /// Reduce a tab's glass to a flat fill with no rim.
    ///
    /// The glass is drawn by a SwiftUI renderer view next to the glass's content.
    /// In its layer tree a plain `CALayer` holds the tint (a fill run through a
    /// filter) and SwiftUI's effect stack is a set of layers named `@0`, `@1`,
    /// ...: the backdrop blur, the rim and specular highlight, and a portal that
    /// actually puts the tab's title on screen (the original is hidden). The
    /// numbering shifts with the tab's contents, so we keep whichever effect
    /// layer carries that portal and hide the rest. Tinting can't reach an exact
    /// colour, so the fill is painted directly.
    @available(macOS 26, *)
    private static func flattenGlass(_ glass: NSGlassEffectView, fill: NSColor) {
        let fillColor = fill.cgColor
        let content = glass.contentView
        for renderer in glass.subviews where !(content?.isDescendant(of: renderer) ?? false) {
            guard let root = renderer.layer else { continue }
            forEachLayer(in: root) { layer in
                if layer.name?.hasPrefix("@") == true {
                    if !showsContent(layer), !layer.isHidden { layer.isHidden = true }
                } else if type(of: layer) == CALayer.self, let current = layer.backgroundColor {
                    // Skip unchanged layers so the per-update sync doesn't redraw.
                    if layer.filters != nil { layer.filters = nil }
                    if current != fillColor { layer.backgroundColor = fillColor }
                }
            }
        }
    }

    /// True if this layer is, or contains, a portal that displays another layer
    /// in place of the original.
    private static func showsContent(_ layer: CALayer) -> Bool {
        if layer.responds(to: NSSelectorFromString("hidesSourceLayer")),
           layer.value(forKey: "hidesSourceLayer") as? Bool == true {
            return true
        }
        return (layer.sublayers ?? []).contains(where: showsContent)
    }

    /// Nudge a colour away from its own lightness: lighter for dark colours,
    /// darker for light ones.
    private static func adjust(_ color: NSColor, by level: CGFloat) -> NSColor {
        (color.isLightColor
            ? color.shadow(withLevel: level)
            : color.highlight(withLevel: level)) ?? color
    }

    @available(macOS 26, *)
    private func squareTabBar(_ tabBarView: NSView) {
        if let root = tabBarView.layer {
            Self.forEachLayer(in: root, Self.squareCorners)
        }
        for case let glass as NSGlassEffectView in tabBarView.descendants(withClassName: "NSGlassEffectView") {
            if glass.cornerRadius != 0 { glass.cornerRadius = 0 }
        }
    }

    private static func squareCorners(of layer: CALayer) {
        // Assigning cornerRadius invalidates the layer even when unchanged, so
        // only touch the rounded ones. NaN means "capsule" here.
        if layer.cornerRadius.isNaN || layer.cornerRadius > 0 {
            layer.cornerRadius = 0
        }
    }

    private static func forEachLayer(in layer: CALayer, _ body: (CALayer) -> Void) {
        body(layer)
        for sub in layer.sublayers ?? [] { forEachLayer(in: sub, body) }
    }

    @available(macOS 13.0, *)
    private func syncAppearanceVentura(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        guard let titlebarContainer else { return }

        // Setup the titlebar background color to match ours
        titlebarContainer.wantsLayer = true
        titlebarContainer.layer?.backgroundColor = preferredBackgroundColor?.cgColor

        // See the docs for the function that sets this to true on why
        effectViewIsHidden = false

        // Necessary to not draw the border around the title
        titlebarAppearsTransparent = true
    }

    // MARK: View Finders

    private var titlebarBackgroundView: NSView? {
        titlebarContainer?.firstDescendant(withClassName: "NSTitlebarBackgroundView")
    }

    // MARK: Tab Group Observation

    private func setupKVO() {
        // This can run from one of the observation callbacks below. Replacing
        // an observation before its callback returns leaves the window retained
        // by AppKit, so always rebind on the next main-queue turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Recheck because the tab group and observation state may have changed
            // while this work was waiting on the main queue.
            let currentTabGroup = self.tabGroup
            let observationsValid = currentTabGroup == nil || (
                self.tabGroupWindowsObservation != nil &&
                self.tabBarVisibleObservation != nil &&
                self.tabSelectionObservation != nil
            )

            // Keep the existing observations when they already match.
            guard self.observedTabGroup !== currentTabGroup || !observationsValid else { return }

            self.observedTabGroup = currentTabGroup
            self.setupTabGroupObservation()
            self.setupTabBarVisibleObservation()
            self.setupTabSelectionObservation()
        }
    }

    /// Monitors the tabGroup windows value for any changes and resyncs the appearance on change.
    /// This is necessary because when the windows change, the tab bar and titlebar are recreated
    /// which breaks our changes.
    private func setupTabGroupObservation() {
        // Remove existing observation if any
        tabGroupWindowsObservation?.invalidate()
        tabGroupWindowsObservation = nil

        // Check if tabGroup is available
        guard let tabGroup else { return }

        // Set up KVO observation for the windows array. Whenever it changes
        // we resync the appearance because it can cause macOS to redraw the
        // tab bar.
        tabGroupWindowsObservation = tabGroup.observe(
            \.windows,
             options: [.new]
        ) { [weak self] _, _ in
            // NOTE: At one point, I guarded this on only if we went from 0 to N
            // or N to 0 under the assumption that the tab bar would only get
            // replaced on those cases. This turned out to be false (Tahoe).
            // It's cheap enough to always redraw this so we should just do it
            // unconditionally.

            guard let self else { return }
            guard let lastSurfaceConfig else { return }
            self.syncAppearance(lastSurfaceConfig)
        }
    }

    /// Monitors the tab bar for visibility. This lets the "Show/Hide Tab Bar" manual menu item
    /// to not break our appearance.
    private func setupTabBarVisibleObservation() {
        // Remove existing observation if any
        tabBarVisibleObservation?.invalidate()
        tabBarVisibleObservation = nil

        // Set up KVO observation for isTabBarVisible
        tabBarVisibleObservation = tabGroup?.observe(
            \.isTabBarVisible,
             options: [.new]
        ) { [weak self] _, _ in
            guard let self else { return }
            guard let lastSurfaceConfig else { return }
            self.syncAppearance(lastSurfaceConfig)
        }
    }

    /// Selecting a tab makes AppKit restyle the tab buttons over a short animation,
    /// recreating the glass layers we neutralised. Re-apply a few times across it.
    private func setupTabSelectionObservation() {
        tabSelectionObservation?.invalidate()
        tabSelectionObservation = nil
        guard #available(macOS 27, *), let tabGroup else { return }

        tabSelectionObservation = tabGroup.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            self.syncTabBarStyle()
            for ms in [50, 150, 300, 600] {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                    self?.syncTabBarStyle()
                }
            }
        }
    }

    // MARK: macOS 13 to 15

    // We only need to set this once, but need to do it after the window has been created in order
    // to determine if the theme is using a very dark background, in which case we don't want to
    // remove the effect view if the default tab bar is being used since the effect created in
    // `updateTabsForVeryDarkBackgrounds` creates a confusing visual design.
    private var effectViewIsHidden = false

    private func hideEffectView() {
        guard !effectViewIsHidden else { return }

        // By hiding the visual effect view, we allow the window's (or titlebar's in this case)
        // background color to show through. If we were to set `titlebarAppearsTransparent` to true
        // the selected tab would look fine, but the unselected ones and new tab button backgrounds
        // would be an opaque color. When the titlebar isn't transparent, however, the system applies
        // a compositing effect to the unselected tab backgrounds, which makes them blend with the
        // titlebar's/window's background.
        if let effectView = titlebarContainer?.descendants(withClassName: "NSVisualEffectView").first {
            effectView.isHidden = true
        }

        effectViewIsHidden = true
    }
}
