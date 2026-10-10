import AppKit
import SceneKit

/// Sculpted pieces: graphite armour, polished metal and restrained light seams.
enum ArenaPieces {
    static func make(_ piece: Piece) -> SCNNode {
        let tint = ArenaPalette.color(for: piece.side)
        let metal = surface(piece.side == .white ? NSColor(calibratedRed: 0.66, green: 0.77, blue: 0.84, alpha: 1) : NSColor(calibratedRed: 0.24, green: 0.18, blue: 0.12, alpha: 1), metallic: 0.8)
        let dark = surface(NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.085, alpha: 1), metallic: 0.7)
        let light = glow(tint)
        let base = SCNCylinder(radius: 0.32, height: 0.09)
        base.radialSegmentCount = 48
        base.materials = [light]
        let root = SCNNode(geometry: base)
        func part(_ geometry: SCNGeometry, _ material: SCNMaterial, _ x: Float = 0, _ y: Float, _ z: Float = 0) -> SCNNode {
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(x, y, z)
            root.addChildNode(node)
            return node
        }
        func ring(_ radius: CGFloat, _ y: Float, _ pipe: CGFloat = 0.015) {
            _ = part(SCNTorus(ringRadius: radius, pipeRadius: pipe), light, 0, y)
        }
        _ = part(SCNCylinder(radius: 0.30, height: 0.10), dark, 0, 0.075)
        _ = part(SCNCone(topRadius: 0.21, bottomRadius: 0.30, height: 0.15), metal, 0, 0.19)
        ring(0.235, 0.235)
        let tall: CGFloat = piece.kind == .pawn ? 0.30 : 0.50
        _ = part(SCNCone(topRadius: 0.12, bottomRadius: 0.21, height: tall), metal, 0, 0.25 + Float(tall / 2))
        let shoulder: Float = 0.25 + Float(tall)
        _ = part(SCNCylinder(radius: 0.21, height: 0.08), dark, 0, shoulder)
        ring(0.21, shoulder + 0.04)
        switch piece.kind {
        case .pawn:
            _ = part(SCNSphere(radius: 0.19), metal, 0, 0.77)
            ring(0.17, 0.78, 0.018)
            _ = part(SCNSphere(radius: 0.055), light, 0, 0.93)
        case .rook:
            _ = part(SCNCylinder(radius: 0.235, height: 0.28), metal, 0, 0.93)
            _ = part(SCNCylinder(radius: 0.17, height: 0.025), light, 0, 1.08)
            for index in 0..<6 {
                let angle = Float(index) * .pi / 3
                let block = part(SCNBox(width: 0.12, height: 0.17, length: 0.12, chamferRadius: 0.015), metal,
                                 sin(angle) * 0.2, 1.13, cos(angle) * 0.2)
                block.eulerAngles.y = CGFloat(angle)
            }
        case .knight:
            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: -0.23, y: 0))
            for point in [NSPoint(x: -0.28, y: 0.28), NSPoint(x: -0.16, y: 0.57), NSPoint(x: -0.12, y: 0.78),
                          NSPoint(x: 0.02, y: 0.67), NSPoint(x: 0.17, y: 0.60), NSPoint(x: 0.35, y: 0.39),
                          NSPoint(x: 0.32, y: 0.24), NSPoint(x: 0.09, y: 0.29), NSPoint(x: 0.02, y: 0.04)] {
                outline.line(to: point)
            }
            outline.close()
            let shape = SCNShape(path: outline, extrusionDepth: 0.19)
            shape.chamferRadius = 0.025
            let head = part(shape, metal, 0, 0.71)
            head.eulerAngles.y = piece.side == .white ? 0.25 : .pi - 0.25
            for z: Float in [-0.11, 0.11] {
                let eye = SCNNode(geometry: SCNSphere(radius: 0.035))
                eye.geometry?.materials = [light]; eye.position = SCNVector3(0.12, 0.50, z)
                head.addChildNode(eye)
            }
            for index in 0..<4 {
                let fin = SCNNode(geometry: SCNBox(width: 0.06, height: 0.09, length: 0.23, chamferRadius: 0.01))
                fin.geometry?.materials = [dark]
                fin.position = SCNVector3(-0.20, Float(index) * 0.105 + 0.18, 0)
                head.addChildNode(fin)
            }
        case .bishop:
            let mitre = part(SCNSphere(radius: 0.20), metal, 0, 1.06)
            mitre.scale = SCNVector3(0.8, 1.55, 0.8)
            let cut = part(SCNBox(width: 0.035, height: 0.32, length: 0.33, chamferRadius: 0.007), dark, 0.05, 1.13)
            cut.eulerAngles.z = -.pi / 5
            _ = part(SCNSphere(radius: 0.048), light, 0, 1.39)
        case .queen:
            _ = part(SCNCone(topRadius: 0.27, bottomRadius: 0.13, height: 0.22), metal, 0, 0.93)
            for index in 0..<7 {
                let angle = Float(index) * 2 * .pi / 7
                _ = part(SCNCone(topRadius: 0.015, bottomRadius: 0.065, height: 0.23), metal,
                         sin(angle) * 0.21, 1.14, cos(angle) * 0.21)
                _ = part(SCNSphere(radius: 0.035), light, sin(angle) * 0.21, 1.27, cos(angle) * 0.21)
            }
            _ = part(SCNSphere(radius: 0.075), light, 0, 1.15)
        case .king:
            _ = part(SCNCone(topRadius: 0.23, bottomRadius: 0.12, height: 0.23), metal, 0, 0.94)
            ring(0.235, 1.05)
            _ = part(SCNBox(width: 0.095, height: 0.43, length: 0.10, chamferRadius: 0.016), metal, 0, 1.29)
            _ = part(SCNBox(width: 0.34, height: 0.09, length: 0.10, chamferRadius: 0.016), metal, 0, 1.36)
            _ = part(SCNBox(width: 0.038, height: 0.31, length: 0.112, chamferRadius: 0.006), light, 0, 1.29)
        }
        return root
    }

    static func surface(_ color: NSColor, metallic: CGFloat = 0.4) -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .physicallyBased
        m.diffuse.contents = color; m.metalness.contents = metallic; m.roughness.contents = 0.42
        return m
    }
    static func glow(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .constant
        m.diffuse.contents = color; m.emission.contents = color
        return m
    }
}
