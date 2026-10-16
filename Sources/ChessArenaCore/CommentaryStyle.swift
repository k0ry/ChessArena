import Foundation

public enum CommentaryStyle: String, CaseIterable, Sendable {
    case house, carlin, zadornov

    public static func turn(_ index: Int) -> Self { allCases[max(0, index) % allCases.count] }

    public var instruction: String {
        let voice: String
        switch self {
        case .house:
            voice = "Use the dry, acerbic wit of Dr. Gregory House: clinically observant, skeptical of grand plans, sharply sarcastic. An occasional diagnostic metaphor is enough; do not turn every line into a medical joke."
        case .carlin:
            voice = "Use George Carlin's incisive observational satire: expose contradictions between impressive labels and ordinary reality, question rules and inflated importance, build a compact logical reversal with a sharp punchline. Focus on chess rituals and decisions; avoid medical metaphors."
        case .zadornov:
            voice = "Use Mikhail Zadornov's conversational observational humor: a familiar everyday comparison, playful language, an apparently sensible explanation followed by an unexpected absurd twist. Keep the target on chess pieces, plans and decisions; avoid medical metaphors and stand-up introductions."
        }
        return "Commentary style: \(rawValue.uppercased()). " + voice
            + " Use only this style for this reply; do not blend the three voices. Write an original joke, not a quotation or catchphrase. Do not announce the style or impersonate the person."
    }

    func fallback(for event: Event, language: BroadcastLanguage, variation: Int) -> String {
        let russian: [String]
        let english: [String]
        switch (self, event) {
        case (.house, .waiting):
            russian = ["Игрок думает. Видимо, даже очевидному решению понадобился консилиум.", "Уверенность взяла паузу. Наконец-то полезный симптом.", "Диагноз почти готов. Осталось убедить в этом самого диагноста."]
            english = ["Still thinking. Apparently the obvious requires a consultation.", "Confidence took a break. Finally, a useful symptom.", "The diagnosis is nearly ready. Someone should tell the diagnostician."]
        case (.carlin, .waiting):
            russian = ["Свобода выбора прекрасна, пока от тебя действительно не потребуют выбрать.", "Назовите нерешительность стратегией — и она сразу выглядит дороже.", "План проходит согласование. Пешки надеются дожить до резолюции."]
            english = ["Freedom of choice is wonderful until someone actually expects you to choose.", "Call indecision strategy and suddenly it looks expensive.", "The plan awaits approval. The pawns hope to survive the paperwork."]
        case (.zadornov, .waiting):
            russian = ["Собрался сделать ход, а получился совет директоров одной пешки.", "Вот ведь как: доска маленькая, а заблудиться в планах можно основательно.", "Думал выбрать ход побыстрее. Теперь выбирает, какой из быстрых способов выбрать."]
            english = ["He set out to make a move and formed a one-pawn board of directors.", "Such a small board, such a large place to get lost in your plans.", "He wanted a quick decision. Now he is choosing the quickest way to choose."]
        case (.house, .move):
            russian = ["Ход сделан. План выглядит уверенно — симптомы пока собираем."]
            english = ["A move, confidently delivered. We are still collecting symptoms."]
        case (.carlin, .move):
            russian = ["Одну фигуру переставили. Всё остальное пока называется стратегией."]
            english = ["One piece moved. Everything else is still being marketed as strategy."]
        case (.zadornov, .move):
            russian = ["Фигура переехала на одну клетку, а планов — как после покупки новой квартиры."]
            english = ["One piece changed squares, with enough plans to furnish a new apartment."]
        case (.house, .final):
            russian = ["Консилиум окончен. Доска оказалась убедительнее амбиций."]
            english = ["Consultation over. The board proved more persuasive than ambition."]
        case (.carlin, .final):
            russian = ["Планы были у всех. В протокол, как назло, попали только ходы."]
            english = ["Everyone had plans. Unfortunately, the record kept only the moves."]
        case (.zadornov, .final):
            russian = ["Вот и разобрались: клеток шестьдесят четыре, а последнее слово всё равно за доской."]
            english = ["Sixty-four squares, and somehow the board still gets the last word."]
        case (.house, .resignation):
            russian = ["Игрок сдаётся. Редкий случай: диагноз признали до вскрытия."]
            english = ["Resignation. A rare diagnosis accepted before the autopsy."]
        case (.carlin, .resignation):
            russian = ["Игрок сдаётся. Иногда признать результат — единственное решение без рекламы."]
            english = ["Resignation. Sometimes accepting the result is the only decision without a sales pitch."]
        case (.zadornov, .resignation):
            russian = ["Игрок сдаётся. Искал выход из положения — нашёл выход из партии."]
            english = ["Resignation. He looked for a way out of the position and found a way out of the game."]
        case (.house, .stall):
            russian = ["Связь зависла. Даже у сервера нашёлся повод уклониться от ответа."]
            english = ["The connection stalled. Even the server found an excuse to avoid answering."]
        case (.carlin, .stall):
            russian = ["Сервис называется доступным. Видимо, это название, а не обязательство."]
            english = ["They call it an available service. Apparently that is branding, not a commitment."]
        case (.zadornov, .stall):
            russian = ["Запрос ушёл. Ответ, похоже, решил добираться с пересадками."]
            english = ["The request departed. The reply apparently booked a connecting route."]
        }
        let choices = language == .russian ? russian : english
        return choices[max(0, variation) % choices.count]
    }

    enum Event { case waiting, move, final, resignation, stall }
}
