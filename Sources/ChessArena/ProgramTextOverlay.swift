import ChessArenaCore
import SwiftUI

/// Text over the board; independent of the controls and model reply sidebar.
struct ProgramTextOverlay: View {
    let picture: BroadcastPicture
    let language: BroadcastLanguage
    var showThinkingNotes = true
    var showTaunts = false

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Text("CHESS / ARENA")
                    .font(.system(size: 28, weight: .black, design: .rounded)).tracking(4)
                Spacer()
            }
            .padding(.horizontal, 40).padding(.top, 24)
            HStack {
                Text(picture.whiteName)
                Spacer()
                Text(picture.clockText).monospacedDigit()
                Spacer()
                Text(picture.blackName)
            }
            .font(.title2.weight(.semibold))
            .padding(.horizontal, 40).padding(.top, 28)

            Text(picture.line)
                .font(.title2)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 980)
                .padding(.horizontal, 40).padding(.top, 12)

            Spacer()
            if let banner = picture.banner {
                Text(banner)
                    .font(.system(size: 56, weight: .bold, design: .serif))
                    .padding(.bottom, showThinkingNotes || showTaunts ? 12 : 42)
            }
            if showTaunts { tauntPanel }
            if showThinkingNotes { notesPanel }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 8)
        .allowsHitTesting(false)
    }

    /// The last taunt with its persona; shown only while the taunt switch is on.
    private var tauntPanel: some View {
        VStack(spacing: 8) {
            if let side = picture.tauntSide, !picture.taunt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let name = side == .white ? picture.whiteName : picture.blackName
                let sideName = language.text(side == .white ? "БЕЛЫЕ" : "ЧЁРНЫЕ", side == .white ? "WHITE" : "BLACK")
                let persona = picture.tauntPersona.map { " · " + $0.uppercased() } ?? ""
                Text("\(name.uppercased()) · \(sideName)\(persona) · " + language.text("СОПЕРНИКУ", "TO THE OPPONENT"))
                    .font(.system(size: 13, weight: .semibold)).tracking(1.6)
                    .foregroundStyle(side == .white ? Color.cyan : Color.orange)
                Text(picture.taunt)
                    .font(.system(size: 26, weight: .medium, design: .serif))
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            } else {
                Text(language.text("Колкость появится после первого хода.", "The first taunt arrives with the first move."))
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
            }
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: 980)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 40).padding(.bottom, showThinkingNotes ? 12 : 42)
    }

    /// The thinking player's note to self; the switch in the control window hides the whole panel.
    private var notesPanel: some View {
        VStack(spacing: 10) {
            if let side = picture.thinkingSide {
                let name = side == .white ? picture.whiteName : picture.blackName
                let sideName = language.text(side == .white ? "БЕЛЫЕ" : "ЧЁРНЫЕ", side == .white ? "WHITE" : "BLACK")
                Text("\(name.uppercased()) · \(sideName) · " + language.text("ЗАМЕТКА СЕБЕ", "NOTE TO SELF"))
                    .font(.system(size: 13, weight: .semibold)).tracking(1.6)
                    .foregroundStyle(side == .white ? Color.cyan : Color.orange)
                let notes = picture.thinkingSelfNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Text(notes.isEmpty ? language.text("Игрок ещё не оставил себе заметку.", "This player has not left a note yet.") : notes)
                    .font(.title2)
                    .lineLimit(6)
                    .minimumScaleFactor(0.8)
            } else {
                Text(language.text("Заметка появится, когда игрок начнёт думать.", "The player's note will appear when they start thinking."))
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
            }
        }
        .multilineTextAlignment(.center)
        .padding(18)
        .frame(maxWidth: 980)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 40).padding(.bottom, 42)
    }
}
