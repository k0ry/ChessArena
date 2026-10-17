import Foundation

/// Contains game data only: transports, credentials and in-flight tasks are never encoded.
public struct GameCheckpoint: Codable, Equatable {
    public var referee: Referee
    public var elapsed: TimeInterval
    public var picture: BroadcastPicture
    public var lastRejection: String?
    public var requestCount: Int
    public var journal: [JournalEntry]
    public var whiteSelfNotes: String? = nil
    public var blackSelfNotes: String? = nil
    public var gameMemory: GameMemory? = nil
}

public struct CameraCheckpoint: Codable, Equatable {
    public var manual: Bool
    public var yaw: Float
    public var pitch: Float
    public var distance: Float
    public var roll: Float? = nil
    public var axis: CameraRotationAxis? = nil
}

public struct SavedSession: Codable {
    public var schemaVersion = 1
    public var game: GameCheckpoint?
    public var series: MatchSeries
    public var white: PlayerConfiguration
    public var black: PlayerConfiguration
    public var hostModel: String
    /// Absent in older sessions, where the host always used Grok.
    public var hostProvider: NeuralProvider?
    /// Absent in older sessions; Claude then uses the subscription through the local CLI.
    public var claudeAccess: ClaudeAccess?
    /// Which comedic persona each model plays; absent in older sessions.
    public var personas: PersonaAssignments?
    public var language: BroadcastLanguage
    public var useChatGPTLogin: Bool
    public var camera: CameraCheckpoint
    public var gameMemory: GameMemory?

    public init(game: GameCheckpoint?, series: MatchSeries, white: PlayerConfiguration,
                black: PlayerConfiguration, hostModel: String, language: BroadcastLanguage,
                useChatGPTLogin: Bool, camera: CameraCheckpoint, hostProvider: NeuralProvider = .grok,
                gameMemory: GameMemory? = nil, claudeAccess: ClaudeAccess = .subscription, personas: PersonaAssignments? = nil) {
        self.game = game; self.series = series; self.white = white; self.black = black
        self.hostModel = hostModel; self.language = language
        self.useChatGPTLogin = useChatGPTLogin; self.camera = camera
        self.hostProvider = hostProvider
        self.gameMemory = gameMemory
        self.claudeAccess = claudeAccess
        self.personas = personas
    }

    public var hostConfiguration: PlayerConfiguration {
        var configuration = PlayerConfiguration(provider: hostProvider ?? .grok)
        configuration.model = hostModel
        return configuration
    }
}

public enum SessionStoreError: Error { case unsupportedVersion, invalidState }

/// Atomic replacement leaves the previous complete file intact if a write fails.
public final class SessionStore {
    public let url: URL
    private var lastWritten: Data?
    public init(url: URL) { self.url = url }

    public func load() throws -> SavedSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let version = try JSONDecoder().decode(Version.self, from: data)
        guard version.schemaVersion == 1 else { throw SessionStoreError.unsupportedVersion }
        let state = try JSONDecoder().decode(SavedSession.self, from: data)
        guard state.camera.yaw.isFinite, state.camera.pitch.isFinite, state.camera.distance.isFinite, state.camera.roll?.isFinite != false,
              !state.series.running || (state.game != nil && state.series.roundID != nil),
              state.series.result == nil || state.series.result == state.game?.referee.end,
              state.series.restartAt?.isFinite != false else { throw SessionStoreError.invalidState }
        if let game = state.game {
            guard game.elapsed.isFinite, game.elapsed >= 0, game.requestCount >= 0,
                  game.referee.accepted.last.map({ $0.fenAfter == game.referee.position.fen }) ?? true,
                  game.referee.accepted.allSatisfy({ move in
                      [move.move.from, move.move.to].allSatisfy { (0..<8).contains($0.file) && (0..<8).contains($0.rank) }
                  }) else { throw SessionStoreError.invalidState }
        }
        return state
    }

    public func save(_ state: SavedSession) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data != lastWritten else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        lastWritten = data
    }

    private struct Version: Decodable { let schemaVersion: Int }
}
