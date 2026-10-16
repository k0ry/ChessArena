import AppKit
import CoreVideo
import Metal
import SceneKit
import Combine
import simd

public enum CameraRotationAxis: String, CaseIterable, Codable {
    case x, y, z
}

public enum ArenaPalette {
    public static let cold = NSColor(calibratedRed: 0.62, green: 0.88, blue: 1.0, alpha: 1)
    public static let amber = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.12, alpha: 1)
    public static let stone = NSColor(calibratedWhite: 0.07, alpha: 1)
    public static let stoneEdge = NSColor(calibratedWhite: 0.16, alpha: 1)

    public static func color(for side: Side) -> NSColor {
        side == .white ? cold : amber
    }

    public static func tint(for side: Side) -> String {
        side == .white ? "cold" : "amber"
    }
}

public final class BoardScene: ObservableObject {
    public let scene = SCNScene()
    public let cameraNode = SCNNode()
    public private(set) var isCameraManual = false
    private var cameraYaw: Float = 0
    private var cameraPitch: Float = 0
    private var cameraDistance: Float = 18
    private var cameraRoll: Float = 0
    @Published public private(set) var selectedCameraAxis: CameraRotationAxis?
    @Published public private(set) var cameraRevision = 0
    public private(set) var isAnimating = false
    public let boardNode = SCNNode()
    private var pieceNodes: [String: SCNNode] = [:]
    private var displayedPosition = Position.standard()
    private let captureEffects = SCNNode()
    private lazy var metalDevice = MTLCreateSystemDefaultDevice()
    private lazy var renderQueue = metalDevice?.makeCommandQueue()
    private lazy var renderer: SCNRenderer = {
        let result = SCNRenderer(device: metalDevice, options: nil)
        result.scene = scene; result.pointOfView = cameraNode
        result.autoenablesDefaultLighting = false
        return result
    }()
    private let pulseNode = SCNNode(geometry: SCNBox(width: 7.2, height: 0.04, length: 3.4, chamferRadius: 0))

    public init() {
        scene.background.contents = NSColor(calibratedWhite: 0.02, alpha: 1)
        scene.rootNode.addChildNode(boardNode)
        captureEffects.name = "capture-effects"
        scene.rootNode.addChildNode(captureEffects)
        buildSquares()
        buildCamera()
        buildStage()
        pulseNode.isHidden = true
        pulseNode.name = "pulse"
        scene.rootNode.addChildNode(pulseNode)
        show(position: .standard())
    }

    public func cameraPosition(at time: TimeInterval) -> SCNVector3 {
        let angle = time * 0.055
        return SCNVector3(Float(sin(angle) * 1.1 + 0.8), 11.7, Float(12.4 + cos(angle) * 0.45))
    }

    public func applyCamera(at time: TimeInterval) {
        guard !isCameraManual else { return }
        cameraNode.position = cameraPosition(at: time)
        cameraNode.look(at: SCNVector3(0, 0, 0), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        cameraRevision &+= 1
    }

    public var onCameraChanged: (() -> Void)?
    public var cameraCheckpoint: CameraCheckpoint {
        CameraCheckpoint(manual: isCameraManual, yaw: cameraYaw, pitch: cameraPitch, distance: cameraDistance,
                         roll: cameraRoll, axis: selectedCameraAxis)
    }
    public func restoreCamera(_ saved: CameraCheckpoint) {
        guard saved.yaw.isFinite, saved.pitch.isFinite, saved.distance.isFinite, saved.roll?.isFinite != false else { return }
        isCameraManual = saved.manual
        cameraYaw = saved.yaw.truncatingRemainder(dividingBy: 2 * .pi)
        cameraPitch = min(.pi * 0.47, max(.pi / 12, saved.pitch))
        cameraDistance = min(45, max(9, saved.distance))
        cameraRoll = (saved.roll ?? 0).truncatingRemainder(dividingBy: 2 * .pi)
        selectedCameraAxis = saved.axis
        if isCameraManual { updateManualCamera() } else { applyCamera(at: 0) }
    }

    public func orbitCamera(yaw: Float, pitch: Float, roll: Float = 0) {
        guard yaw.isFinite, pitch.isFinite, roll.isFinite else { return }
        beginManualCamera()
        if selectedCameraAxis == nil || selectedCameraAxis == .y {
            cameraYaw = (cameraYaw + yaw).truncatingRemainder(dividingBy: 2 * .pi)
        }
        if selectedCameraAxis == nil || selectedCameraAxis == .x {
            cameraPitch = min(.pi * 0.47, max(.pi / 12, cameraPitch + pitch))
        }
        if selectedCameraAxis == .z {
            let delta = roll != 0 ? roll : (abs(yaw) >= abs(pitch) ? yaw : pitch)
            cameraRoll = (cameraRoll + delta).truncatingRemainder(dividingBy: 2 * .pi)
        }
        updateManualCamera()
        onCameraChanged?()
    }

    public func zoomCamera(scale: Float) {
        guard scale.isFinite, scale > 0 else { return }
        beginManualCamera()
        cameraDistance = min(45, max(9, cameraDistance * scale))
        updateManualCamera()
        onCameraChanged?()
    }

    public func resetCamera() {
        isCameraManual = true
        cameraYaw = 0
        cameraPitch = atan2(11.7, 12.85)
        cameraDistance = sqrt(11.7 * 11.7 + 12.85 * 12.85)
        cameraRoll = 0
        selectedCameraAxis = nil
        updateManualCamera()
        onCameraChanged?()
    }

    public func selectCameraAxis(_ axis: CameraRotationAxis?) {
        beginManualCamera()
        selectedCameraAxis = axis
        updateManualCamera()
        onCameraChanged?()
    }

    /// Trackpad twist uses the same axis restriction as dragging either the board or gizmo.
    public func rotateCamera(by angle: Float) {
        orbitCamera(yaw: angle, pitch: selectedCameraAxis == .x ? angle : 0, roll: angle)
    }

    public func cameraProjection(of vector: SIMD3<Float>) -> SIMD3<Float> {
        cameraNode.simdOrientation.inverse.act(vector)
    }

    private func beginManualCamera() {
        guard !isCameraManual else { return }
        let position = cameraNode.position
        let x = Float(position.x), y = Float(position.y), z = Float(position.z)
        let horizontal = sqrt(x * x + z * z)
        cameraDistance = sqrt(horizontal * horizontal + y * y)
        cameraYaw = atan2(x, z)
        cameraPitch = atan2(y, horizontal)
        isCameraManual = true
    }

    private func updateManualCamera() {
        let horizontal = cameraDistance * cos(cameraPitch)
        cameraNode.position = SCNVector3(horizontal * sin(cameraYaw), cameraDistance * sin(cameraPitch), horizontal * cos(cameraYaw))
        // Rebuild orientation from absolute angles: look(at:) can retain roll and introduce drift.
        cameraNode.simdOrientation = simd_quatf(angle: cameraYaw, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: -cameraPitch, axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: cameraRoll, axis: SIMD3(0, 0, 1))
        cameraRevision &+= 1
    }

    public func setThinking(_ side: Side?) {
        guard let side else {
            pulseNode.isHidden = true
            return
        }
        pulseNode.isHidden = false
        pulseNode.removeAllActions()
        pulseNode.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.15, duration: 1.3), .fadeOpacity(to: 0.55, duration: 1.3)])))
        pulseNode.name = side == .white ? "pulse-white" : "pulse-black"
        pulseNode.geometry?.firstMaterial = material(ArenaPalette.color(for: side), transparent: true)
        pulseNode.position = SCNVector3(0, 0.2, side == .white ? -2 : 2)
    }

    public func show(position: Position) {
        clearCaptureEffects()
        isAnimating = false
        displayedPosition = position
        pieceNodes.values.forEach { $0.removeFromParentNode() }
        pieceNodes.removeAll()
        for index in 0..<64 {
            guard let piece = position.squares[index] else { continue }
            let square = Square(file: index % 8, rank: index / 8)
            addPiece(piece, at: square)
        }
    }

    public func animate(move: ChessMove, positionAfter: Position, side: Side, duration: TimeInterval) {
        let before = displayedPosition
        let movingKind = before.piece(at: move.from)?.kind
        let capturedSquare = movingKind == .pawn && move.to == before.enPassant && before.piece(at: move.to) == nil
            ? Square(file: move.to.file, rank: move.from.rank) : move.to
        let captured = before.piece(at: capturedSquare)
        let hasCapture = captured.map { $0.side != side } ?? false
        let approach = hasCapture ? duration * 0.35 : duration
        show(position: positionAfter)
        func slide(from: Square, to: Square) {
            guard duration > 0, let node = pieceNodes[to.uci] else { return }
            let destination = node.position
            node.position = world(from, kind: .pawn)
            let action = SCNAction.move(to: destination, duration: approach)
            action.timingMode = .easeInEaseOut
            node.runAction(action, forKey: "move")
        }
        slide(from: move.from, to: move.to)
        if movingKind == .king, abs(move.to.file - move.from.file) == 2 {
            slide(from: Square(file: move.to.file > move.from.file ? 7 : 0, rank: move.from.rank),
                  to: Square(file: move.to.file > move.from.file ? 5 : 3, rank: move.from.rank))
        }
        if duration > 0, hasCapture, let captured {
            eject(captured, at: capturedSquare, delay: approach, duration: duration - approach)
        }
        clearTrails()
        addTrail(move: move, side: side)
        isAnimating = duration > 0
    }

    public func finishAnimation() {
        clearCaptureEffects()
        isAnimating = false
        for (uci, node) in pieceNodes {
            node.removeAction(forKey: "move")
            if let square = Square(uci: uci) { node.position = world(square, kind: .pawn) }
        }
    }

    private func eject(_ piece: Piece, at square: Square, delay: TimeInterval, duration: TimeInterval) {
        // A visual copy cannot participate in board state or later moves.
        let flying = ArenaPieces.make(piece)
        flying.name = "captured-" + square.uci
        let bounds = flying.boundingBox
        let center = (bounds.max.y + bounds.min.y) / 2
        flying.pivot = SCNMatrix4MakeTranslation(0, center, 0)
        var start = world(square, kind: piece.kind)
        start.y += center
        flying.position = start
        captureEffects.addChildNode(flying)
        let flight = CaptureFlight(start: start)
        let tumble = SCNAction.customAction(duration: duration) { node, elapsed in
            let pose = flight.pose(at: Double(elapsed) / duration)
            node.position = pose.position
            node.eulerAngles = pose.rotation
            node.opacity = pose.opacity
        }
        flying.runAction(.sequence([.wait(duration: delay), tumble, .removeFromParentNode()]))

        let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.38, pipeRadius: 0.025))
        ring.name = "capture-flash"
        ring.geometry?.materials = [ArenaPieces.glow(ArenaPalette.color(for: piece.side))]
        ring.position = world(square, kind: .pawn)
        ring.opacity = 0
        captureEffects.addChildNode(ring)
        ring.runAction(.sequence([.wait(duration: delay), .fadeIn(duration: 0.04),
            .group([.scale(to: 2.8, duration: duration * 0.5), .fadeOut(duration: duration * 0.5)]),
            .removeFromParentNode()]))
    }

    private func clearCaptureEffects() {
        captureEffects.childNodes.forEach { $0.removeAllActions(); $0.removeFromParentNode() }
    }

    public func layChronicle(moves: [ChessMove], sides: [Side]) {
        clearTrails()
        var position = Position.standard()
        for (move, side) in zip(moves, sides) {
            addTrail(move: move, side: side)
            position = position.applying(move)
        }
        show(position: position)
    }

    public func copyFrame() -> CVPixelBuffer? {
        guard let image = renderFrame() else { return nil }
        let buffer = FrameBuffer.make()
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
        let context = CGContext(
            data: base,
            width: StageMetrics.width,
            height: StageMetrics.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        var proposed = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: StageMetrics.width, height: StageMetrics.height))
        }
        return buffer
    }

    public func renderFrame(size: CGSize = CGSize(width: StageMetrics.width, height: StageMetrics.height)) -> NSImage? {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        guard let bytes = renderedBGRA(width: width, height: height) else { return nil }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmap = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmap,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    public func renderedBGRA(width: Int, height: Int) -> [UInt8]? {
        guard let device = metalDevice, let queue = renderQueue else { return nil }

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let color = device.makeTexture(descriptor: colorDescriptor) else { return nil }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        guard let depth = device.makeTexture(descriptor: depthDescriptor) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
        renderer.render(
            atTime: CACurrentMediaTime(),
            viewport: CGRect(x: 0, y: 0, width: width, height: height),
            commandBuffer: commandBuffer,
            passDescriptor: pass
        )
        if colorDescriptor.storageMode == .managed, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(texture: color, slice: 0, level: 0)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let row = width * 4
        var bytes = [UInt8](repeating: 0, count: row * height)
        bytes.withUnsafeMutableBytes { raw in
            color.getBytes(raw.baseAddress!, bytesPerRow: row, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }

    public func node(named name: String) -> SCNNode? {
        scene.rootNode.childNode(withName: name, recursively: true)
    }

    private func buildSquares() {
        boardNode.name = "board"
        for rank in 0..<8 {
            for file in 0..<8 {
                let box = SCNBox(width: 0.96, height: 0.18, length: 0.96, chamferRadius: 0.02)
                let square = SCNNode(geometry: box)
                let dark = (file + rank).isMultiple(of: 2)
                box.materials = [ArenaPieces.surface(dark ? NSColor(calibratedRed: 0.025, green: 0.045, blue: 0.07, alpha: 1) : NSColor(calibratedRed: 0.17, green: 0.22, blue: 0.27, alpha: 1), metallic: 0.05)]
                box.firstMaterial?.roughness.contents = 0.72
                square.position = SCNVector3(Float(file) - 3.5, 0, Float(rank) - 3.5)
                square.name = "square-\(file)\(rank)"
                boardNode.addChildNode(square)
            }
        }
    }

    private func buildCamera() {
        let camera = SCNCamera()
        camera.zFar = 200
        camera.fieldOfView = 37
        camera.wantsHDR = true
        camera.bloomIntensity = 0.45
        camera.bloomThreshold = 0.75
        camera.bloomBlurRadius = 5
        camera.wantsExposureAdaptation = false
        cameraNode.camera = camera
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)
        applyCamera(at: 0)
    }

    private func addPiece(_ piece: Piece, at square: Square) {
        let node = ArenaPieces.make(piece)
        node.position = world(square, kind: piece.kind)
        node.name = pieceName(kind: piece.kind, uci: square.uci)
        scene.rootNode.addChildNode(node)
        pieceNodes[square.uci] = node
    }

    private func addTrail(move: ChessMove, side: Side) {
        let start = world(move.from, kind: .pawn)
        let end = world(move.to, kind: .pawn)
        let dx = end.x - start.x
        let dz = end.z - start.z
        let length = max(0.2, sqrt(dx * dx + dz * dz))
        let box = SCNBox(width: CGFloat(length), height: 0.06, length: 0.08, chamferRadius: 0)
        box.materials = [material(ArenaPalette.color(for: side))]
        let node = SCNNode(geometry: box)
        node.position = SCNVector3((start.x + end.x) / 2, 0.28, (start.z + end.z) / 2)
        node.eulerAngles.y = -atan2(dz, dx)
        node.name = "trail-\(ArenaPalette.tint(for: side))-\(move.uci)"
        scene.rootNode.addChildNode(node)
    }

    private func clearTrails() {
        scene.rootNode.childNodes.filter { $0.name?.hasPrefix("trail-") == true }.forEach {
            $0.removeFromParentNode()
        }
    }

    private func world(_ square: Square, kind: PieceKind) -> SCNVector3 {
        SCNVector3(Float(square.file) - 3.5, height(kind), Float(square.rank) - 3.5)
    }

    private func height(_ kind: PieceKind) -> Float { 0.16 }

    private func buildStage() {
        func add(_ geometry: SCNGeometry, _ material: SCNMaterial, _ position: SCNVector3) -> SCNNode {
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry); node.position = position
            scene.rootNode.addChildNode(node); return node
        }
        _ = add(SCNBox(width: 8.65, height: 0.42, length: 8.65, chamferRadius: 0.18),
                ArenaPieces.surface(NSColor(calibratedWhite: 0.055, alpha: 1), metallic: 0.8), SCNVector3(0, -0.29, 0))
        for side in [Side.white, Side.black] {
            let color = ArenaPalette.color(for: side)
            let z: Float = side == .white ? -4.25 : 4.25
            _ = add(SCNBox(width: 8.1, height: 0.035, length: 0.045, chamferRadius: 0.02), ArenaPieces.glow(color), SCNVector3(0, -0.11, z))
            for x: Float in [-4.25, 4.25] {
                _ = add(SCNBox(width: 0.045, height: 0.035, length: 4.15, chamferRadius: 0.02), ArenaPieces.glow(color), SCNVector3(x, -0.11, z / 2))
            }
        }
        let floor = SCNFloor(); floor.reflectivity = 0.12
        _ = add(floor, ArenaPieces.surface(NSColor(calibratedWhite: 0.025, alpha: 1)), SCNVector3(0, -0.53, 0))
        for i in -8...8 {
            let m = ArenaPieces.glow(NSColor(calibratedRed: 0.025, green: 0.07, blue: 0.09, alpha: 1))
            _ = add(SCNBox(width: 0.008, height: 0.005, length: 24, chamferRadius: 0), m, SCNVector3(Float(i) * 1.5, -0.52, 0))
            _ = add(SCNBox(width: 24, height: 0.005, length: 0.008, chamferRadius: 0), m, SCNVector3(0, -0.52, Float(i) * 1.5))
        }
        for i in 0..<8 {
            let text = SCNText(string: String(UnicodeScalar(65 + i)!), extrusionDepth: 0.001)
            text.font = NSFont.monospacedSystemFont(ofSize: 0.20, weight: .medium)
            text.flatness = 0.1
            let label = add(text, ArenaPieces.glow(ArenaPalette.amber), SCNVector3(Float(i) - 3.56, 0.01, 4.05))
            label.eulerAngles.x = -.pi / 2
        }
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 450; ambient.light?.color = NSColor(calibratedRed: 0.62, green: 0.73, blue: 0.86, alpha: 1)
        scene.rootNode.addChildNode(ambient)
        for (position, color, intensity) in [(SCNVector3(-5, 9, 5), NSColor.white, CGFloat(950)),
                                            (SCNVector3(4, 6, -5), ArenaPalette.cold, CGFloat(650)),
                                            (SCNVector3(2, 5, 6), ArenaPalette.amber, CGFloat(700))] {
            let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni
            light.light?.intensity = intensity; light.light?.color = color; light.position = position
            scene.rootNode.addChildNode(light)
        }
    }

    private func material(_ color: NSColor, transparent: Bool = false) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        if transparent {
            material.transparency = 0.85
        }
        return material
    }

    private func pieceName(kind: PieceKind, uci: String) -> String {
        "piece-\(kindName(kind))-\(uci)"
    }

    private func kindName(_ kind: PieceKind) -> String {
        switch kind {
        case .pawn: return "pawn"
        case .knight: return "knight"
        case .bishop: return "bishop"
        case .rook: return "rook"
        case .queen: return "queen"
        case .king: return "king"
        }
    }

    private func pieceKind(on position: Position, square: Square) -> PieceKind? {
        position.piece(at: square)?.kind
    }
}
