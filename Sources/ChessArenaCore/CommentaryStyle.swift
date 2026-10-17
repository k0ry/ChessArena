import Foundation

/// The host speaks in one voice of humor. Styles no longer rotate; the enum stays for the prompt and fallbacks.
public enum CommentaryStyle: String, CaseIterable, Sendable {
    case zadornov

    public static func turn(_ index: Int) -> Self { .zadornov }

    public var instruction: String {
        let voice = "Use Mikhail Zadornov's conversational observational humor: a familiar everyday comparison, playful language, an apparently sensible explanation followed by an unexpected absurd twist. Keep the target on chess pieces, plans and decisions; avoid medical metaphors and stand-up introductions."
        return "Commentary style: \(rawValue.uppercased()). " + voice
            + " Use only this style for this reply. Write an original joke, not a quotation or catchphrase. Do not announce the style or impersonate the person."
    }

    func fallback(for event: Event, language: BroadcastLanguage, variation: Int) -> String {
        let russian: [String]
        let english: [String]
        switch event {
        case .waiting:
            russian = ["Собрался сделать ход, а получился совет директоров одной пешки.", "Вот ведь как: доска маленькая, а заблудиться в планах можно основательно.", "Думал выбрать ход побыстрее. Теперь выбирает, какой из быстрых способов выбрать."]
            english = ["He set out to make a move and formed a one-pawn board of directors.", "Such a small board, such a large place to get lost in your plans.", "He wanted a quick decision. Now he is choosing the quickest way to choose."]
        case .move:
            russian = ["Фигура переехала на одну клетку, а планов — как после покупки новой квартиры.", "Ход сделан. Фигура довольна, остальные пока осматривают новые обязанности.", "Переставили одну фигуру, а переживают почему-то все шестнадцать."]
            english = ["One piece changed squares, with enough plans to furnish a new apartment.", "The move is made. One piece is pleased, the rest are reviewing their new duties.", "One piece moved, and somehow all sixteen look worried."]
        case .final:
            russian = ["Вот и разобрались: клеток шестьдесят четыре, а последнее слово всё равно за доской.", "Партия окончена. Планов было на три партии, хватило ровно на одну."]
            english = ["Sixty-four squares, and somehow the board still gets the last word.", "The game is over. There were plans for three games; they lasted exactly one."]
        case .resignation:
            russian = ["Игрок сдаётся. Искал выход из положения — нашёл выход из партии."]
            english = ["Resignation. He looked for a way out of the position and found a way out of the game."]
        case .stall:
            russian = ["Запрос ушёл. Ответ, похоже, решил добираться с пересадками."]
            english = ["The request departed. The reply apparently booked a connecting route."]
        }
        let choices = language == .russian ? russian : english
        return choices[max(0, variation) % choices.count]
    }

    enum Event { case waiting, move, final, resignation, stall }
}
