import ChessArenaCore
import SwiftUI

/// A projected sphere tracks the board's actual orientation. Rings and labels select an axis.
struct CameraOrbitControl: View {
    @ObservedObject var scene: BoardScene
    let language: BroadcastLanguage
    @State private var previousDrag: CGSize = .zero
    private let center = CGPoint(x: 76, y: 76)
    private let radius: CGFloat = 57

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.16), .black.opacity(0.85)], center: .topLeading,
                                         startRadius: 0, endRadius: 145))
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                    .padding(15)
                Canvas { context, _ in
                    for axis in CameraRotationAxis.allCases {
                        let points = ring(axis)
                        let selected = scene.selectedCameraAxis == axis
                        for index in 1..<points.count {
                            var path = Path()
                            path.move(to: points[index - 1].point)
                            path.addLine(to: points[index].point)
                            let front = points[index].depth >= 0
                            context.stroke(path, with: .color(color(axis).opacity(selected ? 1 : (front ? 0.65 : 0.2))),
                                           style: StrokeStyle(lineWidth: selected ? 3.5 : 1.5, lineCap: .round))
                        }
                    }
                    context.fill(Path(ellipseIn: CGRect(x: 73, y: 73, width: 6, height: 6)), with: .color(.white.opacity(0.6)))
                }
                .contentShape(Circle())
                .onTapGesture { location in
                    let closest = CameraRotationAxis.allCases.map { axis in
                        (axis, ring(axis).map { hypot($0.point.x - location.x, $0.point.y - location.y) }.min() ?? 100)
                    }.min { $0.1 < $1.1 }
                    if let closest, closest.1 < 13 { toggle(closest.0) }
                }
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let delta = CGSize(width: value.translation.width - previousDrag.width,
                                           height: value.translation.height - previousDrag.height)
                        previousDrag = value.translation
                        scene.orbitCamera(yaw: -Float(delta.width) * 0.008, pitch: Float(delta.height) * 0.008)
                    }
                    .onEnded { _ in previousDrag = .zero })
                // Fixed labels remain easy to click even when a projected axis points into the screen.
                ForEach(CameraRotationAxis.allCases, id: \.self) { axis in
                    Button { toggle(axis) } label: {
                        Text(axis.rawValue.uppercased())
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(scene.selectedCameraAxis == axis ? Color.black : color(axis))
                            .frame(width: 30, height: 30)
                            .background(scene.selectedCameraAxis == axis ? color(axis) : Color(white: 0.08), in: Circle())
                            .overlay(Circle().stroke(color(axis), lineWidth: scene.selectedCameraAxis == axis ? 2.5 : 1))
                            .shadow(color: color(axis).opacity(scene.selectedCameraAxis == axis ? 0.6 : 0), radius: 7)
                    }
                    .buttonStyle(.plain)
                    .position(labelPosition(axis))
                    .help(axisDescription(axis))
                    .accessibilityLabel(axisDescription(axis))
                    .accessibilityValue(scene.selectedCameraAxis == axis ? language.text("Выбрана", "Selected") : "")
                }
            }
            .frame(width: 152, height: 152)
            Text(scene.selectedCameraAxis.map(axisDescription) ?? language.text("Свободное вращение", "Free rotation"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Button(language.text("Все оси", "All axes")) { scene.selectCameraAxis(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.cyan)
                .disabled(scene.selectedCameraAxis == nil)
                .opacity(scene.selectedCameraAxis == nil ? 0.35 : 1)
        }
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 22))
        .help(language.text("Выберите X, Y или Z, затем перетаскивайте доску или сферу. Повторное нажатие освобождает все оси.",
                            "Select X, Y or Z, then drag the board or sphere. Select the same axis again for free rotation."))
    }

    private func toggle(_ axis: CameraRotationAxis) {
        scene.selectCameraAxis(scene.selectedCameraAxis == axis ? nil : axis)
    }

    private func ring(_ axis: CameraRotationAxis) -> [(point: CGPoint, depth: Float)] {
        (0...80).map { index in
            let angle = Float(index) / 80 * 2 * .pi
            let c = cos(angle), s = sin(angle)
            let vector: SIMD3<Float>
            switch axis {
            case .x: vector = SIMD3(0, c, s)
            case .y: vector = SIMD3(c, 0, s)
            case .z: vector = SIMD3(c, s, 0)
            }
            let projected = scene.cameraProjection(of: vector)
            return (CGPoint(x: center.x + CGFloat(projected.x) * radius,
                            y: center.y - CGFloat(projected.y) * radius), projected.z)
        }
    }

    private func color(_ axis: CameraRotationAxis) -> Color {
        switch axis { case .x: return .red; case .y: return .green; case .z: return .cyan }
    }

    private func labelPosition(_ axis: CameraRotationAxis) -> CGPoint {
        switch axis {
        case .x: return CGPoint(x: 135, y: 76)
        case .y: return CGPoint(x: 76, y: 17)
        case .z: return CGPoint(x: 32, y: 125)
        }
    }

    private func axisDescription(_ axis: CameraRotationAxis) -> String {
        switch axis {
        case .x: return language.text("X · наклон", "X · tilt")
        case .y: return language.text("Y · поворот", "Y · orbit")
        case .z: return language.text("Z · крен", "Z · roll")
        }
    }
}
