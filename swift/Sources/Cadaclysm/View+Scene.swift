// A reader scene, or one node of it, in a View of one's own (CadaclysmView), by handle.
import CadaclysmView

extension View {
    /// A reader scene by handle. The item keeps the scene alive until it is removed or the
    /// view closed; `Scene.close()` removes it first.
    @discardableResult
    public func showScene(_ scene: Scene) throws -> Item {
        try showHandle(solid: nil, scene: scene.liveOrThrow(), tolerance: 0, rgb: nil, owner: scene)
    }

    /// A node: its scene by handle with the siblings along its path hidden (Python's
    /// _show_node; framing it is the caller's). The item keeps the scene alive.
    @discardableResult
    public func showNode(_ node: Node) throws -> Item {
        let item = try showScene(node.scene)
        for hidden in node.siblingsAlongPath { try item.nodeVisible(hidden, false) }
        return item
    }
}
