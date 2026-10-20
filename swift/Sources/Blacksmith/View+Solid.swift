// A kernel solid in a View of one's own (CadaclysmView), by handle.
import CadaclysmView

extension View {
    /// A kernel solid by handle, exact where its surfaces draw, triangles at `tolerance`
    /// otherwise; `rgb` (numbers or text, see Colour) nil keeps its paint. The item keeps the
    /// solid alive until it is removed or the view closed.
    @discardableResult
    public func showSolid(_ solid: Solid, tolerance: Double = 0.05, rgb: (any Colour)? = nil) throws -> Item {
        try showHandle(solid: solid.h(), scene: nil, tolerance: tolerance, rgb: rgb, owner: solid)
    }
}
