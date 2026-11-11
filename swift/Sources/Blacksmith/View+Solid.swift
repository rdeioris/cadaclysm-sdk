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
}
