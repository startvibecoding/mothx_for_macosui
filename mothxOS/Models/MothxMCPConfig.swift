import Foundation

/// One `name`/`value` entry used by MCP `headers` and `env` arrays.
///
/// The identity is client-local: it exists so SwiftUI lists can bind to a
/// stable row while the user edits, and it is never encoded to the server.
struct MothxMCPPair: Identifiable, Hashable {
    var id = UUID()
    var name: String = ""
    var value: String = ""

    init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}

extension MothxMCPPair: Codable {
    private enum CodingKeys: String, CodingKey { case name, value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
    }
}

/// One MCP server entry, mirroring the `mcp.json` schema mothx reads from
/// `~/.mothx/mcp.json` (global) and `<workDir>/.mothx/mcp.json` (project).
///
/// Transport behavior:
/// - `stdio`: spawned via `command` + `args`, with optional `env`.
/// - `http`: streamable HTTP endpoint at `url`, with optional `headers`.
/// - `sse`: legacy SSE stream at `url` plus `messageUrl` for client POSTs.
struct MothxMCPServer: Identifiable, Hashable {
    var id = UUID()
    var name: String = ""
    /// Empty values are normalized to `stdio` by the server.
    var type: String = MothxMCPServer.stdioType
    var command: String = ""
    var url: String = ""
    var messageUrl: String = ""
    var args: [String] = []
    var headers: [MothxMCPPair] = []
    var env: [MothxMCPPair] = []
    /// Newer `mcp.json` documents carry an `enabled` boolean (absent means
    /// enabled). Kept so read-modify-write round trips never drop it.
    var enabled: Bool?

    static let stdioType = "stdio"
    static let httpType = "http"
    static let sseType = "sse"
    static let transportOptions = [stdioType, httpType, sseType]

    init(
        id: UUID = UUID(),
        name: String = "",
        type: String = MothxMCPServer.stdioType,
        command: String = "",
        url: String = "",
        messageUrl: String = "",
        args: [String] = [],
        headers: [MothxMCPPair] = [],
        env: [MothxMCPPair] = [],
        enabled: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.command = command
        self.url = url
        self.messageUrl = messageUrl
        self.args = args
        self.headers = headers
        self.env = env
        self.enabled = enabled
    }

    var isStdio: Bool { type == MothxMCPServer.stdioType }
    var isSSE: Bool { type == MothxMCPServer.sseType }

    /// Starter stdio entry used by the "basic template" button.
    static func basicTemplate() -> MothxMCPServer {
        MothxMCPServer(name: "example-stdio", type: stdioType, command: "/absolute/path/to/mcp-server")
    }

    /// Multi-transport starter set used by the "full template" button. The
    /// obvious placeholder values are skipped by mothx at startup.
    static func fullTemplates() -> [MothxMCPServer] {
        [
            MothxMCPServer(
                name: "local-stdio",
                type: stdioType,
                command: "/absolute/path/to/mcp-server",
                args: ["--port", "8080"],
                env: [MothxMCPPair(name: "API_KEY", value: "replace-me")]
            ),
            MothxMCPServer(
                name: "remote-http",
                type: httpType,
                url: "https://mcp.example.com",
                headers: [MothxMCPPair(name: "Authorization", value: "Bearer replace-me")]
            ),
            MothxMCPServer(
                name: "legacy-sse",
                type: sseType,
                url: "https://legacy.example.com/sse",
                messageUrl: "https://legacy.example.com/messages",
                headers: [MothxMCPPair(name: "Authorization", value: "Bearer replace-me")]
            ),
        ]
    }
}

extension MothxMCPServer: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, type, command, url, messageUrl, args, headers, env, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        let rawType = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        type = rawType.isEmpty ? MothxMCPServer.stdioType : rawType
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        messageUrl = try container.decodeIfPresent(String.self, forKey: .messageUrl) ?? ""
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        headers = try container.decodeIfPresent([MothxMCPPair].self, forKey: .headers) ?? []
        env = try container.decodeIfPresent([MothxMCPPair].self, forKey: .env) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        if !command.isEmpty { try container.encode(command, forKey: .command) }
        if !url.isEmpty { try container.encode(url, forKey: .url) }
        if !messageUrl.isEmpty { try container.encode(messageUrl, forKey: .messageUrl) }
        if !args.isEmpty { try container.encode(args, forKey: .args) }
        if !headers.isEmpty { try container.encode(headers, forKey: .headers) }
        if !env.isEmpty { try container.encode(env, forKey: .env) }
        if let enabled { try container.encode(enabled, forKey: .enabled) }
    }
}

/// Top-level `mcp.json` document: `{"mcpServers":[...]}`.
struct MothxMCPConfig: Codable {
    var mcpServers: [MothxMCPServer]

    init(mcpServers: [MothxMCPServer] = []) {
        self.mcpServers = mcpServers
    }

    private enum CodingKeys: String, CodingKey { case mcpServers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mcpServers = try container.decodeIfPresent([MothxMCPServer].self, forKey: .mcpServers) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mcpServers, forKey: .mcpServers)
    }
}
