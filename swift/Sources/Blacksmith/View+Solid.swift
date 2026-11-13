// A kernel solid in a View of one's own (CadaclysmView), by handle.
import CadaclysmView

extension View {
    /// A kernel solid by handle, exact where its surfaces draw, triangles at `tolerance`
    /// otherwise; `rgb` (numbers or text, see Colour) nil keeps its paint. The item keeps the
    /// solid alive until it is removed or the view closed. `material` (view ABI 1.21) how it is
    /// lit; `opacity` 0...1 (1 opaque); `faces` the solid's face numbers to show alone, with no
    /// edges -- a trim's ghost (nil: every face). Without any of the three, the 1.4 call. The
    /// item's faces are numbered as the solid numbers them.
    @discardableResult
    public func showSolid(_ solid: Solid, tolerance: Double = 0.05, rgb: (any Colour)? = nil,
                          material: View.Material? = nil, opacity: Float? = nil, faces: [UInt32]? = nil) throws -> Item {
        try showHandle(solid: solid.h(), scene: nil, tolerance: tolerance, rgb: rgb, owner: solid,
                       material: material, opacity: opacity, faces: faces)
    }

    /// A 2D shape over the window (view ABI 1.24): `shape` in pixels (one profile unit a pixel,
    /// y up), its origin hung `x`, `y` pixels inward from `anchor` -- a closed profile filled
    /// (holes cut, even-odd), stroked where `style` says (see OverlayStyle). Drawn after
    /// everything else, never moved by the camera, kept in place as the window resizes; a
    /// click on it picks it (`ViewPick.overlay`) and nothing beneath.
    @discardableResult
    public func showOverlay(_ shape: Profile, anchor: Anchor, x: Float, y: Float,
                            style: OverlayStyle = OverlayStyle()) throws -> Overlay {
        try showOverlay([shape], anchor: anchor, x: x, y: y, style: style)
    }
    /// Several profiles as one overlay -- a crosshair's two strokes, a frame's two loops: their
    /// fills together by the even-odd rule. The fill falls back on the first coloured profile's
    /// colour.
    @discardableResult
    public func showOverlay(_ shapes: [Profile], anchor: Anchor, x: Float, y: Float,
                            style: OverlayStyle = OverlayStyle()) throws -> Overlay {
        if shapes.isEmpty { throw ViewError("show_overlay: at least one profile") }
        var beziers: [Float] = []
        var own: [Float]?
        for p in shapes {
            beziers += try p.beziers().map { Float($0) }
            if own == nil, let c = try p.colour { own = [Float(c.x), Float(c.y), Float(c.z), 1] }
        }
        return try showOverlayCurves(beziers, own: own, anchor: anchor, x: x, y: y, style: style)
    }
}
