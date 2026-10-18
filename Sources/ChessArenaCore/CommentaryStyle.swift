import Foundation

/// The host speaks in one voice of humor. Styles no longer rotate; the enum stays for the prompt and fallbacks.
public enum CommentaryStyle: String, CaseIterable, Sendable {
    case zadornov

    public static func turn(_ index: Int) -> Self { .zadornov }

    public var instruction: String {
        let voice = "Use conversational observational humor and playful language grounded in this position. Everyday comparisons are optional; do not turn every move into the same setup followed by an absurd twist. Keep the target on chess pieces, plans and decisions; avoid medical metaphors and stand-up introductions."
        return voice + " Write original lines, without quotations, catchphrases, real people's names or impersonation. Never announce a persona or comedic style."
    }

    func fallback(for event: Event, language: BroadcastLanguage, variation: Int) -> String {
        let russian: [String]
        let english: [String]
        switch event {
        case .waiting:
            russian = ["Собрался сделать ход, а получился совет директоров одной пешки.", "Вот ведь как: доска маленькая, а заблудиться в планах можно основательно.", "Думал выбрать ход побыстрее. Теперь выбирает, какой из быстрых способов выбрать.", "У этой паузы уже есть собственный характер.", "Интересно, план ещё строится или уже проходит проверку?", "Пешки стоят смирно. Редкое согласие в этом коллективе.", "Красивый замысел сейчас ищет законный адрес.", "Тишина пока играет без ошибок."]
            english = ["He set out to make a move and formed a one-pawn board of directors.", "Such a small board, such a large place to get lost in your plans.", "He wanted a quick decision. Now he is choosing the quickest way to choose.", "This pause is developing a personality of its own.", "Is the plan still under construction, or already being inspected?", "The pawns stand still. A rare moment of agreement.", "An elegant idea is looking for a legal address.", "Silence has made no mistakes so far."]
        case .move:
            russian = ["Фигура переехала на одну клетку, а планов — как после покупки новой квартиры.", "Ход сделан. Фигура довольна, остальные пока осматривают новые обязанности.", "Переставили одну фигуру, а переживают почему-то все шестнадцать.", "На доске новая деталь. Инструкция по сборке опять не приложена.", "Замысел получил адрес. Посмотрим, удобные ли там соседи.", "Любопытно, что на это скажет другая половина доски?", "Клетка занята, вопросы остались.", "За этот ход теперь отвечает его автор."]
            english = ["One piece changed squares, with enough plans to furnish a new apartment.", "The move is made. One piece is pleased, the rest are reviewing their new duties.", "One piece moved, and somehow all sixteen look worried.", "A new arrangement, still without assembly instructions.", "The plan has an address. Let us see about the neighbours.", "What will the other half of the board say to that?", "The square is occupied; the questions remain.", "The author now gets to stand behind this move."]
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
