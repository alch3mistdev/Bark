import CoreGraphics

/// Pure placement math for the recording HUD. Decides where the floating panel
/// goes: anchored just under the text caret when the focused field exposes one
/// (enhanced HUD), otherwise a fixed spot near the bottom of the screen. The
/// panel never takes focus, so a wrong guess is cosmetic, never destructive.
///
/// Coordinates: AX reports the caret in top-left-origin global coordinates;
/// AppKit panels use bottom-left-origin. `primaryHeight` (height of the menu-bar
/// display) converts between them. All inputs are plain values so this is unit
/// tested without a screen.
public enum HUDPlacement {
    /// Default anchor: horizontally centered, a fixed margin above the screen
    /// bottom (AppKit coords). Used when no caret is available or anchoring is off.
    public static func bottomCenter(panelSize: CGSize, visibleFrame: CGRect, bottomMargin: CGFloat = 120) -> CGPoint {
        CGPoint(x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.minY + bottomMargin)
    }

    /// Anchor the panel just below the caret. `caretAX` is the AX caret rect in
    /// top-left global coords; the result is the AppKit bottom-left origin for the
    /// panel, clamped to `visibleFrame`. Returns nil if the caret rect is empty or
    /// degenerate (caller falls back to `bottomCenter`).
    public static func underCaret(
        caretAX: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        primaryHeight: CGFloat,
        gap: CGFloat = 8
    ) -> CGPoint? {
        guard caretAX.width.isFinite, caretAX.height.isFinite,
              caretAX.height > 0, caretAX.height < 2000,
              caretAX.minX.isFinite, caretAX.minY.isFinite else { return nil }

        // Flip the caret's BOTTOM edge into AppKit, then drop the panel below it.
        let caretBottomAppKit = primaryHeight - (caretAX.origin.y + caretAX.height)
        let originY = caretBottomAppKit - gap - panelSize.height
        let originX = caretAX.minX - 2   // left-align the panel a hair left of the caret

        return clamp(CGPoint(x: originX, y: originY), panelSize: panelSize, into: visibleFrame)
    }

    /// Keep the whole panel on `visibleFrame`.
    public static func clamp(_ origin: CGPoint, panelSize: CGSize, into frame: CGRect) -> CGPoint {
        let maxX = frame.maxX - panelSize.width
        let maxY = frame.maxY - panelSize.height
        let x = min(max(origin.x, frame.minX), max(frame.minX, maxX))
        let y = min(max(origin.y, frame.minY), max(frame.minY, maxY))
        return CGPoint(x: x, y: y)
    }
}
