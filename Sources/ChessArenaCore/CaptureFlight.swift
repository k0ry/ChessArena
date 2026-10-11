import SceneKit

/// Deterministic arc, shared by live rendering and the archive renderer.
struct CaptureFlight {
    let start: SCNVector3

    func pose(at progress: Double) -> (position: SCNVector3, rotation: SCNVector3, opacity: CGFloat) {
        let t = Float(min(1, max(0, progress)))
        let direction: Float = start.x < 0 ? -1 : 1
        let x = Float(start.x) + (direction * 7.2 - Float(start.x)) * t
        let z = Float(start.z) + (start.z < 0 ? -2 : 2) * t
        let y = Float(start.y) + 3.8 * sin(.pi * t) - 1.5 * t
        let rotation = SCNVector3(.pi * 1.8 * t, .pi * 2.5 * direction * t, .pi * 0.8 * direction * t)
        return (SCNVector3(x, y, z), rotation, CGFloat(min(1, max(0, (1 - t) / 0.3))))
    }
}
