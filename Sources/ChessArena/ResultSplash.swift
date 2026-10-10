import ChessArenaCore
import SwiftUI

struct SeriesScoreboard: View {
    let whiteName: String
    let blackName: String
    let score: SeriesScore
    let language: BroadcastLanguage

    var body: some View {
        VStack(spacing: 5) {
            Text(language.text("ОБЩИЙ СЧЁТ", "SERIES SCORE"))
                .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(4)
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 22) {
                Text(whiteName).foregroundStyle(.cyan).frame(width: 170, alignment: .trailing)
                Text("\(score.white) : \(score.black)")
                    .font(.system(size: 36, weight: .black, design: .rounded)).monospacedDigit()
                Text(blackName).foregroundStyle(.orange).frame(width: 170, alignment: .leading)
            }
            .font(.system(size: 21, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 30).padding(.vertical, 12)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.2)))
    }
}

struct ResultSplash: View {
    let title: String
    let whiteName: String
    let blackName: String
    let score: SeriesScore
    let seconds: Int?
    let language: BroadcastLanguage
    let winner: Side?
    private var accent: Color { winner == .black ? .orange : .cyan }

    var body: some View {
        ZStack {
            Color(red: 0.012, green: 0.022, blue: 0.05)
            LinearGradient(colors: [.cyan.opacity(0.17), .clear, .orange.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(accent.opacity(0.14)).frame(width: 660, height: 660).blur(radius: 110).offset(y: -60)
            VStack(spacing: 26) {
                Text("CHESS / ARENA").font(.system(size: 20, weight: .black, design: .rounded)).tracking(8)
                    .foregroundStyle(.white.opacity(0.5))
                Image(systemName: winner == nil ? "equal.circle" : "crown.fill")
                    .font(.system(size: 84, weight: .light))
                    .foregroundStyle(LinearGradient(colors: [.white, accent], startPoint: .top, endPoint: .bottom))
                    .shadow(color: accent.opacity(0.6), radius: 28)
                Text(title.uppercased())
                    .font(.system(size: 72, weight: .black, design: .rounded))
                    .minimumScaleFactor(0.45).lineLimit(1)
                    .frame(maxWidth: 1460)
                    .shadow(color: accent.opacity(0.45), radius: 22)
                Text(language.text("ПАРТИЯ №\(score.games) ЗАВЕРШЕНА", "GAME \(score.games) COMPLETE"))
                    .font(.system(size: 16, weight: .medium, design: .monospaced)).tracking(5)
                    .foregroundStyle(.white.opacity(0.5))
                HStack(spacing: 65) {
                    scoreColumn(whiteName, value: score.white, color: .cyan)
                    Text(":").font(.system(size: 88, weight: .ultraLight)).foregroundStyle(.white.opacity(0.25))
                    scoreColumn(blackName, value: score.black, color: .orange)
                }
                .padding(.horizontal, 70).padding(.vertical, 22)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.12)))
                if let seconds {
                    VStack(spacing: 14) {
                        Text(language.text("СЛЕДУЮЩАЯ ПАРТИЯ ЧЕРЕЗ \(seconds) С", "NEXT GAME IN \(seconds) S"))
                            .font(.system(size: 19, weight: .bold, design: .monospaced)).monospacedDigit().tracking(2)
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule().fill(accent)
                                .frame(width: 480 * Double(30 - min(30, max(0, seconds))) / 30)
                        }
                        .frame(width: 480, height: 5)
                        .animation(.linear(duration: 1), value: seconds)
                    }
                    .padding(.top, 12)
                } else {
                    Text(language.text("СЕРИЯ ОСТАНОВЛЕНА", "SERIES STOPPED"))
                        .font(.system(size: 18, weight: .medium, design: .monospaced)).tracking(3)
                }
            }
            .padding(.top, 55)
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    private func scoreColumn(_ name: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: 100, weight: .black, design: .rounded)).monospacedDigit()
            Text(name).font(.system(size: 24, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .frame(width: 300)
    }
}
