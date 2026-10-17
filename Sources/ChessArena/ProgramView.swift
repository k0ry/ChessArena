import AppKit
import ChessArenaCore
import SceneKit
import SwiftUI

struct ProgramView: View {
    @ObservedObject var runtime: MatchRuntime

    private let replyColumn: CGFloat = 460

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                BoardContainer(scene: runtime.scene)
                ProgramTextOverlay(picture: runtime.picture, language: runtime.language,
                                   showThinkingNotes: runtime.showThinkingNotes, showTaunts: runtime.showTaunts)
                CameraOrbitControl(scene: runtime.scene, language: runtime.language)
                    .padding(.trailing, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ReplyWindow(picture: runtime.picture, language: runtime.language)
                .padding(28)
                .frame(width: replyColumn)
        }
        .frame(width: CGFloat(StageMetrics.width), height: CGFloat(StageMetrics.height))
        .background(Color.black)
        .overlay {
            if runtime.result != nil && runtime.showResultSplash {
                ResultSplash(title: runtime.resultTitle,
                             whiteName: runtime.picture.whiteName, blackName: runtime.picture.blackName,
                             score: runtime.score, seconds: runtime.nextGameIn, language: runtime.language,
                             winner: runtime.result?.winner)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            SeriesScoreboard(whiteName: runtime.picture.whiteName, blackName: runtime.picture.blackName,
                             score: runtime.score, language: runtime.language)
                .padding(.top, 18)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            WindowDragArea()
                .frame(height: 72)
                .accessibilityHidden(true)
        }
    }
}

private struct ReplyWindow: View {
    let picture: BroadcastPicture
    let language: BroadcastLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(language.text("РЕПЛИКИ ИГРОКОВ", "PLAYER COMMS"))
                .font(.system(size: 13, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 18)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if picture.replies.isEmpty && picture.thinkingSide == nil {
                            Text(language.text("Ждём первый ход.", "Waiting for the first reply."))
                                .font(.system(size: 22, weight: .medium, design: .serif))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        ForEach(picture.replies) { reply in
                            ReplyCard(reply: reply)
                                .id(reply.id)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                }
                .onChange(of: picture.replies.last?.id) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .frame(maxHeight: .infinity)

            if let player = picture.pausedPlayer {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(player.uppercased()) · " + language.text("ПОВТОР ЗАПРОСА", "RETRYING"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(language.text("Повторяем автоматически…", "Retrying automatically…"))
                        .font(.system(size: 22, weight: .medium, design: .serif))
                }
                .foregroundStyle(.orange)
                .padding(24)
            } else if let side = picture.thinkingSide {
                ThinkingLine(name: side == .white ? picture.whiteName : picture.blackName, side: side, language: language)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct ReplyCard: View {
    let reply: ModelReply

    var body: some View {
        let color = Color(nsColor: ArenaPalette.color(for: reply.side))
        VStack(alignment: .leading, spacing: 8) {
            Text(reply.name.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(color.opacity(0.72))
            replyBody(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func replyBody(_ color: Color) -> some View {
        let trimmed = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let intent = ChatParser.moveIntent(from: trimmed) {
            Text(intent.move)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
            if !intent.taunt.isEmpty {
                Text(intent.taunt)
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(trimmed.isEmpty ? "…" : trimmed)
                .font(.system(size: 28, weight: .medium, design: .serif))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ThinkingLine: View {
    let name: String
    let side: Side
    let language: BroadcastLanguage
    @State private var dim = false

    var body: some View {
        let color = Color(nsColor: ArenaPalette.color(for: side))
        VStack(alignment: .leading, spacing: 6) {
            Text(name.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(color.opacity(0.72))
            Text(language.text("думает…", "thinking…"))
                .font(.system(size: 28, weight: .medium, design: .serif))
                .foregroundStyle(color)
                .opacity(dim ? 0.4 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                dim = true
            }
        }
    }
}

struct BoardContainer: NSViewRepresentable {
    let scene: BoardScene

    func makeNSView(context: Context) -> InteractiveBoardView {
        let view = InteractiveBoardView()
        view.arena = scene
        view.scene = scene.scene
        view.pointOfView = scene.cameraNode
        view.allowsCameraControl = false
        view.isPlaying = true
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 30
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        return view
    }

    func updateNSView(_ view: InteractiveBoardView, context: Context) {
        view.arena = scene
        view.scene = scene.scene
        view.pointOfView = scene.cameraNode
    }
}

/// Controls the same camera used by the screen and archive renderer.
final class InteractiveBoardView: SCNView {
    var arena: BoardScene?
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        arena?.orbitCamera(yaw: -Float(event.deltaX) * 0.008, pitch: Float(event.deltaY) * 0.008)
    }

    override func mouseUp(with event: NSEvent) { NSCursor.openHand.set() }

    override func scrollWheel(with event: NSEvent) {
        let sensitivity: Float = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
        arena?.zoomCamera(scale: exp(-Float(event.scrollingDeltaY) * sensitivity))
    }

    override func magnify(with event: NSEvent) {
        arena?.zoomCamera(scale: exp(-Float(event.magnification)))
    }

    override func rotate(with event: NSEvent) {
        arena?.rotateCamera(by: Float(event.rotation) * .pi / 180)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
