import AppKit
import SwiftUI

/// Where a view is on screen, and the window holding it, read on demand.
/// Hover events do not reach a popover's window while the menu's panel is
/// not the key window, so a hover-opened list follows the pointer by
/// position instead (`SessionCountLabel`).
final class ScreenFrameProbe {
    weak var view: NSView?

    /// Whether `point`, in screen coordinates, is on the view, within
    /// `margin` points of it.
    func contains(_ point: CGPoint, margin: CGFloat = 6) -> Bool {
        guard let view, let window = view.window else { return false }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        return frame.insetBy(dx: -margin, dy: -margin).contains(point)
    }

    /// Whether `point` is on the window holding the view, as a popover's
    /// whole panel with its arrow.
    func windowContains(_ point: CGPoint, margin: CGFloat = 4) -> Bool {
        guard let frame = view?.window?.frame else { return false }
        return frame.insetBy(dx: -margin, dy: -margin).contains(point)
    }
}

/// Puts a `ScreenFrameProbe` on the view it backs.
struct ScreenFrameProbeView: NSViewRepresentable {
    let probe: ScreenFrameProbe

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        probe.view = view
    }
}
