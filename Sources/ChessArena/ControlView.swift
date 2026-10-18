import AppKit
import ChessArenaCore
import SwiftUI

struct ControlView: View {
    @ObservedObject var runtime: MatchRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.cyan)
                Text("CHESS / ARENA").font(.system(size: 22, weight: .black, design: .rounded))
                Spacer()
                Button("Log", systemImage: "doc.text.magnifyingglass", action: runtime.showLog)
                    .help("Запросы к моделям, ответы и ошибки")
            }
            Button("Log сети", systemImage: "network", action: runtime.showNetworkLog)
                .help("HTTP-статусы, время запросов, ошибки подключения и локального CLI")
            Text(runtime.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            Divider()
            if let error = runtime.persistenceError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PlayerPanel(title: "БЕЛЫЕ", color: .cyan, player: $runtime.whitePlayer,
                                runtime: runtime, connection: runtime.chatGPT, gemini: runtime.gemini, claude: runtime.claude)
                    PlayerPanel(title: "ЧЁРНЫЕ", color: .orange, player: $runtime.blackPlayer,
                                runtime: runtime, connection: runtime.chatGPT, gemini: runtime.gemini, claude: runtime.claude)
                    PlayerPanel(title: "РЕФЕРИ / КОММЕНТАТОР", color: .green, player: $runtime.hostPlayer,
                                runtime: runtime, connection: runtime.chatGPT, gemini: runtime.gemini, claude: runtime.claude, isHost: true)
                    Text("Модель комментирует партию. Легальность ходов и результат проверяет шахматный движок.")
                        .font(.caption).foregroundStyle(.secondary)
                    if runtime.needsGrok {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("ПОДКЛЮЧЕНИЕ GROK", systemImage: "key.fill")
                                .foregroundStyle(.cyan).font(.caption.bold())
                            SecureField("API-ключ xAI", text: $runtime.grokKey)
                        }
                    }
                    if runtime.needsGemini {
                        GeminiPanel(connection: runtime.gemini, locked: runtime.matchRunning)
                    }
                    if runtime.needsClaude {
                        ClaudePanel(runtime: runtime, connection: runtime.claude)
                    }
                    if runtime.needsLC0 {
                        LC0Panel(connection: runtime.lc0, locked: runtime.matchRunning && !runtime.paused)
                    }
                    if runtime.needsDeepSeek {
                        DeepSeekPanel(runtime: runtime, connection: runtime.deepseek)
                    }
                    Picker("Язык эфира и озвучки", selection: $runtime.language) {
                        ForEach(BroadcastLanguage.allCases) { Text($0.name).tag($0) }
                    }
                    .disabled(runtime.matchRunning)
                    Toggle("Показывать заметку думающего игрока на сцене", isOn: $runtime.showThinkingNotes)
                        .help("Панель «Заметка себе» внизу доски. После запуска скрыта; на запросы, журнал и архив не влияет")
                    Toggle("Показывать колкость игрока на сцене", isOn: $runtime.showTaunts)
                        .help("Последняя колкость сопернику с именем персоны внизу доски. После запуска скрыта; на запросы, журнал и архив не влияет")
                    SpeechPanel(runtime: runtime, voice: runtime.voice)
                    if runtime.voiceProvider == .system && !SystemVoice.hasMaleVoice(for: runtime.language) {
                        Text("Для языка эфира не установлен мужской системный голос, ведущий пока звучит доступным голосом с пониженным тоном. Скачайте \(runtime.language == .russian ? "Yuri (русский)" : "Daniel или Reed (английский)") в Системных настройках → Универсальный доступ → Устный контент → Системный голос → Управление голосами.")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text("Общий счёт: \(runtime.score.white) : \(runtime.score.black)")
                        Spacer()
                    }
                    if runtime.needsChatGPT {
                        ChatGPTPanel(runtime: runtime, connection: runtime.chatGPT)
                    }
                }
                .padding(.trailing, 4)
            }
            Divider()
            HStack {
                Button("Продолжить партию", action: runtime.continueMatch)
                    .buttonStyle(.borderedProminent).tint(.cyan)
                    .disabled(!runtime.canContinueMatch)
                    .help("Продолжить с сохранённой позиции и прежним счётом")
                Button("Начать новую партию", action: runtime.startNewGame)
                    .help("Начать с исходной позиции, сохранив счёт серии")
            }
            HStack {
                Button("Начать новую серию", action: runtime.startNewSeries)
                    .help("Начать новую партию и обнулить счёт серии")
                Button("Стоп", action: runtime.stopMatch).disabled(!runtime.matchRunning)
                Button("Проверка тона", action: runtime.tone)
                    .disabled(!runtime.canPreviewVoice || runtime.previewProfile != nil)
            }
            HStack {
                Button("Повторить запрос", systemImage: "arrow.clockwise", action: runtime.repeatPlayerRequest)
                    .disabled(!runtime.canRepeatRequest)
                    .help("Отменить ожидание и повторить последний запрос игроку, чей сейчас ход")
                Spacer()
                Button("Сбросить вид", systemImage: "viewfinder") { runtime.scene.resetCamera() }
                    .help("Выровнять край доски параллельно низу окна и зафиксировать ракурс. Ось вращения выбирается на сфере справа от доски")
            }
            Text("Ход \(runtime.moveNumber) · 1920 × 1080")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("Для эфира выберите окно ChessArena Program в OBS. Голос добавьте через захват звука приложения.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Закрыть приложение", systemImage: "power") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(26)
        .frame(width: 500, height: 700)
        .preferredColorScheme(.dark)
        .onAppear { runtime.loadKeys() }
    }
}

private struct PlayerPanel: View {
    let title: String
    let color: Color
    @Binding var player: PlayerConfiguration
    @ObservedObject var runtime: MatchRuntime
    @ObservedObject var connection: ChatGPTConnection
    @ObservedObject var gemini: GeminiConnection
    @ObservedObject var claude: ClaudeConnection
    var isHost = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "circle.fill").foregroundStyle(color).font(.caption.bold())
            Picker("Нейросеть", selection: $player.provider) {
                ForEach(NeuralProvider.allCases.filter { !isHost || $0.supportsHost }) { Text($0.rawValue).tag($0) }
            }
            .disabled(runtime.matchRunning)
            if player.provider == .lc0 {
                Text("Leela Chess Zero · локальный UCI").font(.caption).foregroundStyle(.secondary)
            } else if player.provider == .gemini {
                Picker("Модель", selection: $player.model) {
                    if !gemini.models.contains(where: { $0.id == player.model }) {
                        Text(player.model + " · каталог не проверен").tag(player.model)
                    }
                    ForEach(gemini.models) { Text($0.name).tag($0.id) }
                }
                .disabled(runtime.matchRunning && !runtime.paused)
                HStack {
                    Button("Проверить модель") { gemini.verify(model: player.model) }
                        .disabled(gemini.busy || (runtime.matchRunning && !runtime.paused))
                    if gemini.verifiedModels.contains(player.model) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            } else if player.provider == .deepseek {
                DeepSeekModelPicker(player: $player, connection: runtime.deepseek)
                    .disabled(runtime.matchRunning && !runtime.paused)
            } else if player.provider == .claude {
                let catalog = runtime.claudeAccess == .subscription ? ClaudeCLI.aliases : claude.models
                Picker("Модель", selection: $player.model) {
                    if !catalog.contains(where: { $0.id == player.model }) {
                        Text(player.model + (runtime.claudeAccess == .subscription ? " · полный ID" : claude.models.isEmpty ? " · каталог не загружен" : " · нет в каталоге")).tag(player.model)
                    }
                    ForEach(catalog) { Text($0.name).tag($0.id) }
                }
                .disabled(runtime.matchRunning && !runtime.paused)
                TextField("ID модели Claude вручную", text: $player.model)
                    .disabled(runtime.matchRunning && !runtime.paused)
            } else if player.provider == .chatGPT && runtime.useChatGPTLogin {
                Picker("Модель", selection: $player.model) {
                    if !connection.models.contains(where: { $0.id == player.model }) {
                        Text(connection.connected ? "Выберите модель" : "Сначала войдите в ChatGPT")
                            .tag(player.model)
                    }
                    ForEach(connection.models) { Text($0.name).tag($0.id) }
                }
                .disabled(!connection.connected || (runtime.matchRunning && !runtime.paused))
            } else {
                TextField("ID модели \(player.provider.rawValue)", text: $player.model)
                    .disabled(runtime.matchRunning && !runtime.paused)
            }
        }
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: player.provider) { _, _ in runtime.selectAvailableChatGPTModels() }
        .onChange(of: runtime.useChatGPTLogin) { _, _ in runtime.selectAvailableChatGPTModels() }
        .onChange(of: connection.models) { _, _ in runtime.selectAvailableChatGPTModels() }
    }
}

private struct DeepSeekModelPicker: View {
    @Binding var player: PlayerConfiguration
    @ObservedObject var connection: DeepSeekConnection

    var body: some View {
        Picker("Модель", selection: $player.model) {
            if !connection.models.contains(where: { $0.id == player.model }) {
                Text(player.model + (connection.models.isEmpty ? " · каталог не загружен" : " · нет в каталоге"))
                    .tag(player.model)
            }
            ForEach(connection.models) { Text($0.name).tag($0.id) }
        }
        TextField("ID модели DeepSeek вручную", text: $player.model)
    }
}

private struct DeepSeekPanel: View {
    @ObservedObject var runtime: MatchRuntime
    @ObservedObject var connection: DeepSeekConnection
    private var locked: Bool { runtime.matchRunning && !runtime.paused }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ПОДКЛЮЧЕНИЕ DEEPSEEK", systemImage: "key.fill")
                .foregroundStyle(.cyan).font(.caption.bold())
            SecureField("API-ключ DeepSeek", text: $runtime.deepSeekKey).disabled(locked)
            Button("Обновить модели") { connection.refresh(key: runtime.deepSeekKey) }
                .disabled(locked || connection.busy)
            Text(connection.status).font(.caption).foregroundStyle(.secondary)
            Text("Официальный API · thinking high").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ChatGPTPanel: View {
    @ObservedObject var runtime: MatchRuntime
    @ObservedObject var connection: ChatGPTConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ПОДКЛЮЧЕНИЕ CHATGPT", systemImage: "person.crop.circle")
                .foregroundStyle(.orange).font(.caption.bold())
            Toggle("Войти через аккаунт ChatGPT", isOn: $runtime.useChatGPTLogin)
                .disabled(runtime.matchRunning)
            if runtime.useChatGPTLogin {
                Text(connection.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Continue with ChatGPT") { connection.signIn() }
                        .disabled(connection.busy || (runtime.matchRunning && !runtime.paused))
                    if connection.busy {
                        ProgressView().controlSize(.small)
                        Button("Отмена") { connection.cancelSignIn() }
                    }
                }
                if !connection.connected {
                    Text("В браузере разрешите ChessArena использовать ваш план ChatGPT. Доступ зависит от плана и разрешений аккаунта.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Проверить озвучку по подписке") { connection.checkSpeech() }
                        .disabled(connection.busy)
                    Text(connection.speechStatus).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(connection.speechSupported == true ? .green : .secondary)
                }
            } else {
                SecureField("API-ключ OpenAI", text: $runtime.chatKey)
            }
        }
        .padding(16)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ClaudePanel: View {
    @ObservedObject var runtime: MatchRuntime
    @ObservedObject var connection: ClaudeConnection

    private var subscription: Binding<Bool> {
        Binding(get: { runtime.claudeAccess == .subscription },
                set: { runtime.claudeAccess = $0 ? .subscription : .apiKey })
    }
    private var locked: Bool { runtime.matchRunning && !runtime.paused }
    private var verifyModel: String {
        [runtime.whitePlayer, runtime.blackPlayer, runtime.hostPlayer].first { $0.provider == .claude }?.model ?? "sonnet"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ПОДКЛЮЧЕНИЕ CLAUDE", systemImage: "person.crop.circle").font(.caption.bold()).foregroundStyle(.purple)
            Toggle("Подписка Claude через локальный Claude Code CLI", isOn: subscription)
                .disabled(runtime.matchRunning)
            if runtime.claudeAccess == .subscription {
                TextField("Путь к claude", text: $connection.path).disabled(locked || connection.busy)
                HStack {
                    Button("Выбрать файл", action: connection.chooseFile)
                    Button("Войти по подписке", action: connection.login)
                }.disabled(locked || connection.busy)
                HStack {
                    Button("Проверить подключение") { connection.verifyCLI(model: verifyModel) }
                        .disabled(locked || connection.busy)
                    if connection.cliVerified {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    if connection.busy {
                        ProgressView().controlSize(.small)
                        Button("Отменить", action: connection.cancel)
                    }
                }
                Text(connection.cliStatus).font(.caption).fixedSize(horizontal: false, vertical: true)
                Text("Вход и сессия хранятся в локальном Claude Code CLI; приложение не читает токены. Проверка отправляет один короткий запрос из лимита подписки. Модели: opus, sonnet, haiku или полный ID.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                SecureField("API-ключ Anthropic", text: $runtime.claudeKey).disabled(locked)
                HStack {
                    Button("Обновить модели") { connection.refresh(key: runtime.claudeKey) }
                        .disabled(connection.busy || locked)
                    if connection.busy {
                        ProgressView().controlSize(.small)
                        Button("Отменить", action: connection.cancel)
                    }
                }
                Text(connection.status).font(.caption).fixedSize(horizontal: false, vertical: true)
                Text("Ключ хранится в Keychain и передаётся только в заголовке запроса к Anthropic. Каталог показывает модели ключа; доступ к модели и кредиты подтверждаются первым запросом.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct GeminiPanel: View {
    @ObservedObject var connection: GeminiConnection
    let locked: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("GEMINI · ЛОКАЛЬНЫЙ CLI", systemImage: "terminal").font(.caption.bold()).foregroundStyle(.mint)
            TextField("Путь к agy", text: $connection.path).disabled(locked || connection.busy)
            HStack {
                Button("Выбрать файл", action: connection.chooseFile)
                Button("Войти через Google", action: connection.login)
            }.disabled(locked || connection.busy)
            HStack {
                Button("Обновить модели", action: connection.refresh).disabled(locked || connection.busy)
                if connection.busy { Button("Отменить", action: connection.cancel) }
            }
            Text(connection.status).font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("Сессия хранится в локальном Antigravity CLI. Проверка модели отправляет один тестовый ход. Доступ и квота зависят от Google-аккаунта.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct SpeechPanel: View {
    @ObservedObject var runtime: MatchRuntime
    @ObservedObject var voice: BroadcastVoice
    @State private var showPersonas = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Озвучка", selection: $runtime.voiceProvider) {
                Text("Системные голоса").tag(VoiceProviderChoice.system)
                Text("OpenAI · API-ключ").tag(VoiceProviderChoice.openAIKey)
                Text("Qwen3-TTS · локально").tag(VoiceProviderChoice.localQwen)
            }.disabled(runtime.previewProfile != nil)
            if runtime.voiceProvider == .openAIKey {
                SecureField("Отдельный API-ключ OpenAI для речи", text: $runtime.speechKey)
                Picker("Голос ведущего", selection: $runtime.openAIVoice) {
                    ForEach(BroadcastVoice.voices, id: \.self) { Text($0).tag($0) }
                }
                Text("Голоса созданы ИИ. API оплачивается отдельно от подписки ChatGPT. Ключ хранится в Keychain; при ошибке звучит системный голос.").font(.caption)
            }
            if runtime.voiceProvider == .localQwen {
                Picker("Голос ведущего", selection: $runtime.qwenVoice) {
                    ForEach(LocalQwenConfiguration.voices, id: \.self) { Text($0).tag($0) }
                }.disabled(runtime.previewProfile != nil)
                Button("Послушать ведущего") { runtime.previewVoice(.host) }
                    .disabled(!runtime.canPreviewVoice || runtime.previewProfile != nil)
                DisclosureGroup("Голоса игроков", isExpanded: $showPersonas) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Белые: \(runtime.personaLabel(for: runtime.whitePlayer)) · Чёрные: \(runtime.personaLabel(for: runtime.blackPlayer))")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(PlayerPersona.allCases, id: \.self) { persona in
                            HStack {
                                Picker(persona.displayName(runtime.language), selection: Binding(
                                    get: { runtime.qwenCasting.voice(for: persona) },
                                    set: { runtime.setQwenVoice($0, for: persona) }
                                )) {
                                    ForEach(LocalQwenConfiguration.voices, id: \.self) { Text($0).tag($0) }
                                }.disabled(runtime.previewProfile != nil)
                                Button { runtime.previewVoice(.persona(persona)) } label: {
                                    Image(systemName: "play.circle")
                                }
                                .accessibilityLabel("Послушать: \(persona.displayName(runtime.language))")
                                .help("Послушать голос и подачу этой персоны")
                                .disabled(!runtime.canPreviewVoice || runtime.previewProfile != nil)
                            }
                        }
                        Text("Это характер реплики, а не голос реального комика. По умолчанию у ведущего и восьми персон разные голоса; любой можно заменить.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 6)
                }
                Text("Qwen3-TTS 1.7B · MLX. Работает на этом Mac без API-ключа. Первый запуск загружает модель в память. Голоса созданы ИИ.").font(.caption)
            }
            if runtime.previewProfile != nil {
                Button("Остановить прослушивание", action: runtime.stopVoicePreview)
            }
            Text(voice.status).font(.caption).textSelection(.enabled)
        }.disabled(runtime.matchRunning)
    }
}


private struct LC0Panel: View {
    @ObservedObject var connection: LC0Connection
    let locked: Bool

    var body: some View {
        GroupBox("ПОДКЛЮЧЕНИЕ LC0") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Исполняемый файл lc0", text: $connection.settings.binary)
                    Button("Выбрать lc0") { chooseFile(weights: false) }
                }
                HStack {
                    TextField("Нейросеть: автопоиск при пустом поле", text: $connection.settings.weights)
                    Button("Выбрать веса") { chooseFile(weights: true) }
                }
                Picker("Вычисления", selection: $connection.settings.backend) {
                    Text("По умолчанию движка").tag("")
                    Text("Metal · GPU Apple").tag("metal")
                    Text("BLAS · CPU").tag("blas")
                    Text("Eigen · CPU").tag("eigen")
                }
                Stepper("Время на ход: \(connection.settings.moveSeconds) с", value: $connection.settings.moveSeconds, in: 1...60)
                HStack {
                    Button("Проверить LC0") { connection.verify() }.disabled(connection.busy)
                    if connection.busy { ProgressView().controlSize(.small) }
                }
                Text(connection.status).font(.caption).textSelection(.enabled)
                Text("Общие настройки для обоих игроков LC0. Движок выбирает ходы, выбранный ведущий комментирует партию.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            .disabled(locked)
        }
    }

    private func chooseFile(weights: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if weights { connection.settings.weights = url.path }
            else { connection.settings.binary = url.path }
        }
    }
}
