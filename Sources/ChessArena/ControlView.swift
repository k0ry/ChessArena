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
            Text(runtime.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PlayerPanel(title: "БЕЛЫЕ", color: .cyan, player: $runtime.whitePlayer,
                                runtime: runtime, connection: runtime.chatGPT)
                    PlayerPanel(title: "ЧЁРНЫЕ", color: .orange, player: $runtime.blackPlayer,
                                runtime: runtime, connection: runtime.chatGPT)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("XAI · GROK И ВЕДУЩИЙ", systemImage: "mic.fill")
                            .foregroundStyle(.cyan).font(.caption.bold())
                        SecureField("API-ключ xAI", text: $runtime.grokKey)
                        TextField("Модель ведущего", text: $runtime.hostModel)
                            .disabled(runtime.matchRunning && !runtime.paused)
                        Text("Ведущий использует Grok независимо от выбора игроков.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Язык эфира и озвучки", selection: $runtime.language) {
                        ForEach(BroadcastLanguage.allCases) { Text($0.name).tag($0) }
                    }
                    .disabled(runtime.matchRunning)
                    HStack {
                        Text("Общий счёт: \(runtime.score.white) : \(runtime.score.black)")
                        Spacer()
                        Button("Сбросить счёт", action: runtime.resetScore).disabled(runtime.matchRunning)
                    }
                    if runtime.needsChatGPT {
                        ChatGPTPanel(runtime: runtime, connection: runtime.chatGPT)
                    }
                }
                .padding(.trailing, 4)
            }
            Divider()
            HStack {
                Button(runtime.matchRunning ? "Игра идёт" : "Начать игру", action: runtime.startMatch)
                    .buttonStyle(.borderedProminent).tint(.cyan)
                    .disabled(runtime.matchRunning)
                Button("Стоп", action: runtime.stopMatch).disabled(!runtime.matchRunning)
                Button("Проверка тона", action: runtime.tone).disabled(runtime.matchRunning)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "circle.fill").foregroundStyle(color).font(.caption.bold())
            Picker("Нейросеть", selection: $player.provider) {
                ForEach(NeuralProvider.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(runtime.matchRunning)
            if player.provider == .chatGPT && runtime.useChatGPTLogin {
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
                }
            } else {
                SecureField("API-ключ OpenAI", text: $runtime.chatKey)
            }
        }
        .padding(16)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}
