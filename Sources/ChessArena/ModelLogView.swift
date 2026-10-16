import AppKit
import ChessArenaCore
import SwiftUI

struct ModelLogView: View {
    @ObservedObject var log: ModelLog
    @State private var selection: UUID?
    @State private var errorsOnly = false
    @State private var follow = true

    private var visible: [ModelLogEntry] { log.entries.filter { !errorsOnly || $0.status == .failed } }
    private var selected: ModelLogEntry? {
        visible.first(where: { $0.id == selection }) ?? visible.first
    }

    static func host(log: ModelLog) -> NSView { NSHostingView(rootView: ModelLogView(log: log)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Label("MODEL LOG", systemImage: "terminal")
                    .font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(.cyan)
                Text("\(log.entries.count) / \(log.capacity)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Toggle("Только ошибки", isOn: $errorsOnly)
                Toggle("Следить", isOn: $follow)
                Button("Копировать") {
                    guard let selected else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selected.text, forType: .string)
                }
                .disabled(selected == nil)
                Button("Очистить") { log.clear(); selection = nil }
                    .disabled(log.entries.isEmpty)
            }
            .toggleStyle(.checkbox)
            .padding(18)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visible) { entry in
                            Button {
                                selection = entry.id
                                follow = false
                            } label: {
                                row(entry)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected?.id == entry.id ? Color.cyan.opacity(0.13) : Color.white.opacity(0.035),
                                                in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding(12)
                }
                .frame(width: 300)
                Divider()
                if let selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Text(selected.context).font(.title2.bold())
                                Spacer()
                                Text(selected.status.rawValue).foregroundStyle(color(selected.status))
                            }
                            Text("\(selected.model) · \(selected.date.formatted(date: .numeric, time: .standard))")
                                .foregroundStyle(.secondary)
                            Text("POST \(selected.endpoint)").font(.system(.caption, design: .monospaced))
                            if let duration = selected.duration {
                                Text(String(format: "Время запроса: %.2f с", duration)).foregroundStyle(.secondary)
                            }
                            section("SYSTEM / INSTRUCTIONS", selected.system)
                            section("USER", selected.user)
                            if let advice = selected.gameAdvice, !advice.isEmpty {
                                section("ПЛАН ИЗ ПРОШЛЫХ ПАРТИЙ · отдельное сообщение", advice)
                            }
                            if let notes = selected.selfNotes, !notes.isEmpty {
                                section("ЗАМЕТКИ ЭТОГО ИГРОКА · отдельное сообщение", notes)
                            }
                            if let response = selected.response { section("ОТВЕТ МОДЕЛИ", response) }
                            if let error = selected.error { section("ОШИБКА", error, tint: color(selected.status)) }
                            if selected.status == .pending {
                                Text("Запрос отправлен. Ожидаем ответ…").foregroundStyle(.orange)
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                    }
                    .id(selected.id)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "text.bubble").font(.system(size: 40)).foregroundStyle(.cyan)
                        Text(errorsOnly ? "Ошибок в журнале нет" : "Запросов пока нет").font(.title2.bold())
                        Text("Здесь появятся запросы игроков и ведущего, ответы и ошибки.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(30)
                }
            }
            Divider()
            Text("В памяти хранятся последние \(log.capacity) запросов. Ключи и токены скрыты. Поля SYSTEM и USER показывают текст, переданный модели.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .frame(minWidth: 860, minHeight: 520)
        .background(Color(white: 0.055))
        .preferredColorScheme(.dark)
        .onChange(of: visible.first?.id) { _, id in if follow { selection = id } }
        .onChange(of: follow) { _, enabled in if enabled { selection = visible.first?.id } }
    }

    private func row(_ entry: ModelLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(entry.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                Spacer()
                Text(entry.status.rawValue).foregroundStyle(color(entry.status))
            }
            .font(.caption)
            Text(entry.context).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            Text(entry.model).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func section(_ title: String, _ value: String, tint: Color = .cyan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(tint)
            Text(value.isEmpty ? "(пусто)" : value)
                .font(.system(size: 13, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func color(_ status: ModelLogEntry.Status) -> Color {
        switch status {
        case .pending: return .orange
        case .received: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
