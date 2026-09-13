import Foundation

/// Response from the official MCP Registry search endpoint
/// (`GET https://registry.modelcontextprotocol.io/v0/servers`).
struct MothxMCPMarketResponse: Codable {
    var servers: [MothxMCPMarketEntry] = []
    var metadata: Metadata?

    struct Metadata: Codable {
        var nextCursor: String?
        var count: Int?
    }

    private enum CodingKeys: String, CodingKey { case servers, metadata }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = try container.decodeIfPresent([MothxMCPMarketEntry].self, forKey: .servers) ?? []
        metadata = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
    }
}

/// One registry result. The registry wraps each server in an envelope, so the
/// identity is the inner server name.
struct MothxMCPMarketEntry: Codable, Identifiable, Hashable {
    var server: MothxMCPMarketServer

    var id: String { server.name }

    private enum CodingKeys: String, CodingKey { case server }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decode(MothxMCPMarketServer.self, forKey: .server)
    }
}

/// The subset of the registry server schema mothxOS needs to build an entry.
/// Only fields that exist in the published schema are decoded; unknown fields
/// are ignored so schema evolution does not break decoding.
struct MothxMCPMarketServer: Codable, Hashable {
    var name: String
    var title: String?
    var description: String?
    var version: String?
    var repository: Repository?
    var packages: [Package]?
    var remotes: [Remote]?

    struct Repository: Codable, Hashable {
        var url: String?
        var source: String?
        var subfolder: String?
    }

    struct Package: Codable, Hashable {
        var registryType: String?
        var identifier: String?
        var version: String?
        var runtimeHint: String?
        var runtimeArguments: [Argument]?
        var environmentVariables: [EnvironmentVariable]?
        var transport: Transport?
    }

    struct Argument: Codable, Hashable {
        var value: String?
        var type: String?
        var name: String?
    }

    struct EnvironmentVariable: Codable, Hashable {
        var name: String
        var description: String?
        var isRequired: Bool?
        var isSecret: Bool?
        var defaultValue: String?

        private enum CodingKeys: String, CodingKey {
            case name, description, isRequired, isSecret
            case defaultValue = "default"
        }
    }

    struct Remote: Codable, Hashable {
        var type: String?
        var url: String?
        var headers: [Header]?
    }

    struct Header: Codable, Hashable {
        var name: String?
    }

    struct Transport: Codable, Hashable {
        var type: String?
    }
}

extension MothxMCPMarketServer {
    /// A short, editable server name derived from the registry name, e.g.
    /// `io.github.daedalus/mcp-sqlite3` → `mcp-sqlite3`.
    var suggestedName: String {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best-effort conversion of a registry entry into a mothx `mcp.json`
    /// server. Package-based entries become `stdio`; remote-only entries become
    /// `http`/`sse`. The result is always shown as an editable card so the user
    /// can fix arguments, add secrets, or rename before saving.
    func makeMCPServer() -> MothxMCPServer? {
        if let package = preferredPackage, let command = package.launchCommand {
            var server = MothxMCPServer()
            server.name = suggestedName
            server.type = MothxMCPServer.stdioType
            server.command = command
            server.args = package.launchArguments
            server.env = (package.environmentVariables ?? []).map {
                MothxMCPPair(name: $0.name, value: $0.defaultValue ?? "")
            }
            return server
        }

        if let remote = preferredRemote, let url = remote.url, !url.isEmpty {
            var server = MothxMCPServer()
            server.name = suggestedName
            server.type = remote.type == "sse" ? MothxMCPServer.sseType : MothxMCPServer.httpType
            server.url = url
            server.headers = (remote.headers ?? []).compactMap { $0.name }.map {
                MothxMCPPair(name: $0, value: "")
            }
            return server
        }

        return nil
    }

    /// Prefers the most widely available install method: npm, then pypi, then
    /// oci (docker), then whatever is listed first.
    private var preferredPackage: Package? {
        let list = packages ?? []
        return list.first { $0.registryType == "npm" }
            ?? list.first { $0.registryType == "pypi" }
            ?? list.first { $0.registryType == "oci" }
            ?? list.first
    }

    /// Prefers an SSE remote when present, otherwise the first remote.
    private var preferredRemote: Remote? {
        let list = remotes ?? []
        return list.first { $0.type == "sse" } ?? list.first
    }
}

extension MothxMCPMarketServer.Package {
    /// The executable to launch for this package, honoring the registry's
    /// `runtimeHint` and falling back to the conventional runner per registry.
    var launchCommand: String? {
        if let hint = runtimeHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            return hint
        }
        switch registryType {
        case "npm": return "npx"
        case "pypi": return "uvx"
        case "oci": return "docker"
        default: return nil
        }
    }

    /// Command arguments assembled from the registry metadata. Explicit
    /// `runtimeArguments` are preserved; a `-y` is injected for npx so the
    /// package can run non-interactively.
    var launchArguments: [String] {
        let identifier = self.identifier ?? ""
        let declared = (runtimeArguments ?? []).compactMap { $0.value }
        switch registryType {
        case "npm":
            var args = declared
            if !args.contains("-y") { args.insert("-y", at: 0) }
            if !identifier.isEmpty { args.append(identifier) }
            return args
        case "oci":
            return ["run", "-i", "--rm"] + declared + (identifier.isEmpty ? [] : [identifier])
        default:
            return declared + (identifier.isEmpty ? [] : [identifier])
        }
    }
}
