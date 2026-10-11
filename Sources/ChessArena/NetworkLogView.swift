import AppKit
import ChessArenaCore
import SwiftUI

struct NetworkLogView: View {
    @ObservedObject var log: NetworkLog
    @State private var selection: UUID?
    @State private var errorsOnly = false
    @State private var follow = true
    private var visible: [NetworkLogEntry] { log.entries.filter { !errorsOnly || $0.status == .failed } }
    private var selected: NetworkLogEntry? { visible.first { $0.id == selection } ?? visible.first }

    static func host(log: NetworkLog) -> NSView { NSHostingView(rootView: Self(log: log)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Label("LOG СЕТИ", systemImage: "network").font(.title3.bold()).foregroundStyle(.cyan)
                Text("\(log.entries.count) / \(log.capacity)").foregroundStyle(.secondary)
                Spacer()
                Toggle("Только ошибки", isOn: $errorsOnly)
                Toggle("Следить", isOn: $follow)
                Button("Копировать") { copy(selected?.text ?? "") }.disabled(selected == nil)
                Button("Копировать всё") { copy(visible.map(\.text).joined(separator: "\n\n────────\n\n")) }
                    .disabled(visible.isEmpty)
                Button("Очистить") { log.clear(); selection = nil }.disabled(log.entries.isEmpty)
            }
            .toggleStyle(.checkbox).padding(18)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visible) { entry in
                            Button {
                                selection = entry.id; follow = false
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(entry.date.formatted(date: .omitted, time: .standard))
                                        Spacer()
                                        Text(entry.status.rawValue).foregroundStyle(color(entry.status))
                                    }.font(.caption)
                                    Text(entry.operation.rawValue).font(.callout.bold())
                                    Text(entry.httpStatus.map { "HTTP \($0)" } ?? (entry.isCLI ? "Локальный CLI" : entry.method))
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected?.id == entry.id ? Color.cyan.opacity(0.14) : .white.opacity(0.04),
                                            in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }.padding(12)
                }.frame(width: 320)
                Divider()
                if let selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(selected.operation.rawValue).font(.title2.bold())
                            Text(selected.status.rawValue).foregroundStyle(color(selected.status))
                            Text(selected.text).font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            if selected.status == .pending {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text("Ожидание: \(Int(max(0, context.date.timeIntervalSince(selected.date)))) с")
                                        .foregroundStyle(.orange).monospacedDigit()
                                }
                            }
                        }.padding(24)
                    }.id(selected.id)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "network").font(.system(size: 40)).foregroundStyle(.cyan)
                        Text(errorsOnly ? "Ошибок в журнале нет" : "Сетевых операций пока нет").font(.title2.bold())
                        Text("Здесь появятся обращения к API, авторизация ChatGPT и вызовы Gemini CLI.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            Text("Последние \(log.capacity) операций с момента запуска, только в памяти. Ключи, токены, заголовки и содержимое запросов не записываются. HTTP внутри Gemini CLI не виден приложению.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 1000, minHeight: 520).background(Color(white: 0.055)).preferredColorScheme(.dark)
        .onChange(of: visible.first?.id) { _, id in if follow { selection = id } }
        .onChange(of: follow) { _, enabled in if enabled { selection = visible.first?.id } }
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    private func color(_ status: NetworkLogEntry.Status) -> Color {
        switch status {
        case .pending: return .orange
        case .success: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
