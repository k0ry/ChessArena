import ChessArenaCore
import SwiftUI

struct ControlView: View {
    @ObservedObject var runtime: MatchRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.cyan)
                Text("CHESS / ARENA").font(.system(size: 22, weight: .black, design: .rounded))
                Spacer()
                Text("CONTROL").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(runtime.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("GROK · WHITE + HOST", systemImage: "circle.fill").foregroundStyle(.cyan).font(.caption.bold())
                SecureField("API-ключ xAI", text: $runtime.grokKey)
                TextField("Модель Grok", text: $runtime.whiteModel)
            }
            ChatGPTPanel(runtime: runtime, connection: runtime.chatGPT)
            Divider()
            HStack {
                Button(runtime.matchRunning ? "Игра идёт" : "Начать игру", action: runtime.startMatch)
                    .buttonStyle(.borderedProminent).tint(.cyan)
                    .disabled(runtime.matchRunning || (runtime.useChatGPTLogin && !runtime.chatGPT.connected))
                Button("Продолжить", action: runtime.resume).disabled(!runtime.paused)
                Button("Проверка тона", action: runtime.tone)
            }
            Text("Ход \(runtime.moveNumber) · 1920 × 1080")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("Для эфира выберите окно ChessArena Program в OBS. Голос добавьте через захват звука приложения.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .textFieldStyle(.roundedBorder)
        .padding(26)
        .frame(width: 500, height: 700)
        .preferredColorScheme(.dark)
        .onAppear { runtime.loadKeys() }
    }
}

private struct ChatGPTPanel: View {
    @ObservedObject var runtime: MatchRuntime
    @ObservedObject var connection: ChatGPTConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("CHATGPT · BLACK", systemImage: "circle.fill").foregroundStyle(.orange).font(.caption.bold())
            Toggle("Войти через аккаунт ChatGPT", isOn: $runtime.useChatGPTLogin)
                .disabled(runtime.matchRunning)
            if runtime.useChatGPTLogin {
                Text(connection.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Continue with ChatGPT") { connection.signIn() }
                        .disabled(connection.busy || runtime.matchRunning)
                    if connection.busy {
                        ProgressView().controlSize(.small)
                        Button("Отмена") { connection.cancelSignIn() }
                    }
                }
                if connection.connected {
                    Picker("Модель", selection: $runtime.blackModel) {
                        ForEach(connection.models) { Text($0.name).tag($0.id) }
                    }
                } else {
                    Text("В браузере разрешите ChessArena использовать ваш план ChatGPT. Доступ зависит от плана и разрешений аккаунта.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                SecureField("API-ключ OpenAI", text: $runtime.chatKey)
                TextField("Модель OpenAI", text: $runtime.blackModel)
            }
        }
        .padding(16)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: connection.connected) { _, connected in
            if connected, !connection.models.contains(where: { $0.id == runtime.blackModel }), let model = connection.models.first {
                runtime.blackModel = model.id
            }
            // Forward connection state so the parent's start button updates too.
            runtime.objectWillChange.send()
        }
    }
}
