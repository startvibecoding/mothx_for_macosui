import Foundation

/// Response from the MCPMarket.cn catalog API
/// (`GET https://mcpmarket.cn/api/servers?page=1&per_page=30&search=...`).
/// The catalog uses offset pagination (page/per_page) instead of a cursor.
struct MothxMCPMarketResponse: Codable {
    var currentPage: Int = 1
    var servers: [MothxMCPMarketEntry] = []
    var totalPages: Int = 0
    var totalServers: Int = 0

    private enum CodingKeys: String, CodingKey {
        case servers
        case currentPage = "current_page"
        case totalPages = "total_pages"
        case totalServers = "total_servers"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPage = try container.decodeIfPresent(Int.self, forKey: .currentPage) ?? 1
        servers = try container.decodeIfPresent([MothxMCPMarketEntry].self, forKey: .servers) ?? []
        totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages) ?? 0
        totalServers = try container.decodeIfPresent(Int.self, forKey: .totalServers) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentPage, forKey: .currentPage)
        try container.encode(servers, forKey: .servers)
        try container.encode(totalPages, forKey: .totalPages)
        try container.encode(totalServers, forKey: .totalServers)
    }
}

/// One MCPMarket.cn catalog row. The list endpoint returns only metadata —
/// installable `mcp_config` is fetched per server via the detail endpoint.
struct MothxMCPMarketEntry: Codable, Identifiable, Hashable {
    var id: String = ""
    var name: String = ""
    var alias: String = ""
    var by: String = ""
    var description: String = ""
    var logo: String = ""
    var url: String = ""
    var stars: Int = 0
    var categories: [String] = []
    var featured: Bool = false
    var hosted: Bool = false
    var mcpType: [String] = []

    private enum CodingKeys: String, CodingKey {
        case name, alias, by, description, logo, url, stars, categories, featured, hosted
        case id = "_id"
        case mcpType = "mcp_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? name
        alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? ""
        by = try container.decodeIfPresent(String.self, forKey: .by) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        logo = try container.decodeIfPresent(String.self, forKey: .logo) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        stars = try container.decodeIfPresent(Int.self, forKey: .stars) ?? 0
        categories = Self.decodeStringList(container, forKey: .categories) ?? []
        featured = try container.decodeIfPresent(Bool.self, forKey: .featured) ?? false
        hosted = try container.decodeIfPresent(Bool.self, forKey: .hosted) ?? false
        mcpType = Self.decodeStringList(container, forKey: .mcpType) ?? []
    }

    /// Accepts both array (`["Server"]`) and scalar ("Server") spellings that
    /// the catalog has accumulated over time.
    private static func decodeStringList(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String]? {
        if let list = try? container.decodeIfPresent([String].self, forKey: key) { return list }
        if let single = try? container.decodeIfPresent(String.self, forKey: key) {
            return single.isEmpty ? [] : [single]
        }
        return nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(alias, forKey: .alias)
        try container.encode(by, forKey: .by)
        try container.encode(description, forKey: .description)
        try container.encode(logo, forKey: .logo)
        try container.encode(url, forKey: .url)
        try container.encode(stars, forKey: .stars)
        try container.encode(categories, forKey: .categories)
        try container.encode(featured, forKey: .featured)
        try container.encode(hosted, forKey: .hosted)
        try container.encode(mcpType, forKey: .mcpType)
    }
}

/// Full MCPMarket.cn server record (`GET /api/servers/{id}`). It carries the
/// installable `mcp_config` (standard `mcpServers` object) that the list
/// endpoint omits.
struct MothxMCPMarketDetail: Codable, Identifiable, Hashable {
    var id: String = ""
    var name: String = ""
    var alias: String = ""
    var mcpConfig: MothxMCPMarketConfig?

    private enum CodingKeys: String, CodingKey {
        case name, alias
        case id = "_id"
        case mcpConfig = "mcp_config"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? name
        alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? ""
        mcpConfig = try container.decodeIfPresent(MothxMCPMarketConfig.self, forKey: .mcpConfig)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(alias, forKey: .alias)
        try container.encodeIfPresent(mcpConfig, forKey: .mcpConfig)
    }
}

/// The `mcp_config` object pulled from a server's detail page. Unlike the
/// app's own `mcp.json` (array of servers), MCPMarket.cn stores it as a
/// name-keyed dictionary, so it is decoded as-is and then flattened.
struct MothxMCPMarketConfig: Codable, Hashable {
    var mcpServers: [String: MothxMCPMarketRawServer] = [:]

    enum CodingKeys: String, CodingKey { case mcpServers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mcpServers = try container.decodeIfPresent([String: MothxMCPMarketRawServer].self, forKey: .mcpServers) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mcpServers, forKey: .mcpServers)
    }
}

/// A single raw server entry inside `mcp_config.mcpServers`, tolerant of the
/// hand-written variations (string vs number values, extra keys, etc.) the
/// catalog accumulates.
struct MothxMCPMarketRawServer: Codable, Hashable {
    var url: String?
    var messageUrl: String?
    var command: String?
    var args: [String]?
    var headers: [String: String]?
    var env: [String: String]?
    var transport: String?
    var type: String?

    private enum CodingKeys: String, CodingKey {
        case url, command, args, headers, env, transport, type
        case messageUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        messageUrl = try container.decodeIfPresent(String.self, forKey: .messageUrl)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args)
        transport = try container.decodeIfPresent(String.self, forKey: .transport)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        headers = Self.decodePairs(container, forKey: .headers)
        env = Self.decodePairs(container, forKey: .env)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(messageUrl, forKey: .messageUrl)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(args, forKey: .args)
        try container.encodeIfPresent(headers, forKey: .headers)
        try container.encodeIfPresent(env, forKey: .env)
        try container.encodeIfPresent(transport, forKey: .transport)
        try container.encodeIfPresent(type, forKey: .type)
    }

    /// Headers/env values are strings in practice; tolerate numbers/booleans
    /// by stringifying them and drop a malformed dict rather than failing the
    /// whole server (losing headers is recoverable at edit time).
    private static func decodePairs(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String: String]? {
        struct AnyScalar: Codable {
            var stringValue: String?

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { stringValue = s }
                else if let n = try? c.decode(Int.self) { stringValue = String(n) }
                else if let d = try? c.decode(Double.self) { stringValue = String(d) }
                else if let b = try? c.decode(Bool.self) { stringValue = String(b) }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                try c.encode(stringValue)
            }
        }
        guard let raw = try? container.decodeIfPresent([String: AnyScalar].self, forKey: key) else { return nil }
        return raw.compactMapValues { $0.stringValue }
    }
}

extension MothxMCPMarketDetail {
    /// Flattens the first usable `mcpServers` entry into a mothx `mcp.json`
    /// server. Remote entries become `http`/`sse`; command entries become
    /// `stdio`. Headers/env are prefilled with the catalog's placeholder
    /// values (e.g. `${API_KEY}`) so the user only has to fill in secrets.
    func makeMCPServer() -> MothxMCPServer? {
        guard let config = mcpConfig else { return nil }
        for (name, raw) in config.mcpServers {
            if let server = raw.makeMCPServer(name: name) { return server }
        }
        return nil
    }
}

extension MothxMCPMarketRawServer {
    func makeMCPServer(name: String) -> MothxMCPServer? {
        var server = MothxMCPServer()
        server.name = name

        if let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            let transport = (transport ?? type ?? "").lowercased()
            if transport.contains("sse") {
                server.type = MothxMCPServer.sseType
                server.url = url
                server.messageUrl = messageUrl ?? ""
            } else {
                server.type = MothxMCPServer.httpType
                server.url = url
            }
            server.headers = (headers ?? [:])
                .map { MothxMCPPair(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name }
            return server
        }

        if let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            server.type = MothxMCPServer.stdioType
            server.command = command
            server.args = args ?? []
            server.env = (env ?? [:])
                .map { MothxMCPPair(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name }
            return server
        }

        return nil
    }
}

// MARK: - ModelScope MCP 市场（https://www.modelscope.cn/mcp）

/// Paginated result of `searchModelScopeMCP`.
struct MothxModelScopeMCPResult {
    var servers: [MothxModelScopeMCPEntry]
    var total: Int
    var hasMore: Bool { total > servers.count }
}

/// Response from the ModelScope MCP catalog
/// (`PUT https://modelscope.cn/api/v1/dolphin/mcpServers`, shared by the MCP
/// square page). Rows arrive with the installable `ServerConfig` attached, so
/// no extra detail fetch is needed for the vast majority of entries.
struct MothxModelScopeMCPResponse: Codable, Hashable {
    var code: Int = 0
    var message: String = ""
    var success: Bool = false
    var data: MothxModelScopeMCPData?

    private enum CodingKeys: String, CodingKey {
        case code = "Code"
        case message = "Message"
        case success = "Success"
        case data = "Data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(Int.self, forKey: .code) ?? 0
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
        data = try container.decodeIfPresent(MothxModelScopeMCPData.self, forKey: .data)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(success, forKey: .success)
        try container.encodeIfPresent(data, forKey: .data)
    }
}

struct MothxModelScopeMCPData: Codable, Hashable {
    var mcpServer: MothxModelScopeMCPMeta = MothxModelScopeMCPMeta()

    init() {}

    private enum CodingKeys: String, CodingKey { case mcpServer = "McpServer" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mcpServer = try container.decodeIfPresent(MothxModelScopeMCPMeta.self, forKey: .mcpServer) ?? MothxModelScopeMCPMeta()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mcpServer, forKey: .mcpServer)
    }
}

struct MothxModelScopeMCPMeta: Codable, Hashable {
    var servers: [MothxModelScopeMCPEntry] = []
    var totalCount: Int = 0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case servers = "McpServers"
        case totalCount = "TotalCount"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = try container.decodeIfPresent([MothxModelScopeMCPEntry].self, forKey: .servers) ?? []
        totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(servers, forKey: .servers)
        try container.encode(totalCount, forKey: .totalCount)
    }
}

/// One ModelScope MCP-square catalog row. Only the fields the mothxOS market
/// browser needs are decoded; everything else is dropped unconditionally.
struct MothxModelScopeMCPEntry: Codable, Identifiable, Hashable {
    var id: Int64 = 0
    var name: String = ""
    var chineseName: String = ""
    var abstract: String = ""
    var abstractCN: String = ""
    var category: [String] = []
    var stars: Int = 0
    var fromSite: String = ""
    var fromSiteIcon: String = ""
    var fromSiteUrl: String = ""
    var license: String = ""
    var tags: [String] = []
    var path: String = ""
    var hosted: Bool = false
    var verified: Bool = false
    var deployedUrl: String = ""
    var serverConfig: [MothxModelScopeServerConfig] = []

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case chineseName = "ChineseName"
        case abstract = "Abstract"
        case abstractCN = "AbstractCN"
        case category = "Category"
        case stars = "Stars"
        case fromSite = "FromSite"
        case fromSiteIcon = "FromSiteIcon"
        case fromSiteUrl = "FromSiteUrl"
        case license = "License"
        case tags = "Tags"
        case path = "Path"
        case hosted = "Hosted"
        case verified = "Verifed"
        case deployedUrl = "DeployedUrl"
        case serverConfig = "ServerConfig"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        chineseName = try container.decodeIfPresent(String.self, forKey: .chineseName) ?? ""
        abstract = try container.decodeIfPresent(String.self, forKey: .abstract) ?? ""
        abstractCN = try container.decodeIfPresent(String.self, forKey: .abstractCN) ?? ""
        category = Self.decodeStringList(container, forKey: .category) ?? []
        stars = try container.decodeIfPresent(Int.self, forKey: .stars) ?? 0
        fromSite = try container.decodeIfPresent(String.self, forKey: .fromSite) ?? ""
        fromSiteIcon = try container.decodeIfPresent(String.self, forKey: .fromSiteIcon) ?? ""
        fromSiteUrl = try container.decodeIfPresent(String.self, forKey: .fromSiteUrl) ?? ""
        license = try container.decodeIfPresent(String.self, forKey: .license) ?? ""
        tags = Self.decodeStringList(container, forKey: .tags) ?? []
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        hosted = try container.decodeIfPresent(Bool.self, forKey: .hosted) ?? false
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        deployedUrl = try container.decodeIfPresent(String.self, forKey: .deployedUrl) ?? ""
        serverConfig = try container.decodeIfPresent([MothxModelScopeServerConfig].self, forKey: .serverConfig) ?? []
    }

    /// Accepts both array ("["Server"]") and scalar ("Server") spellings.
    private static func decodeStringList(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String]? {
        if let list = try? container.decodeIfPresent([String].self, forKey: key) { return list }
        if let single = try? container.decodeIfPresent(String.self, forKey: key) {
            return single.isEmpty ? [] : [single]
        }
        return nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(chineseName, forKey: .chineseName)
        try container.encode(abstract, forKey: .abstract)
        try container.encode(abstractCN, forKey: .abstractCN)
        try container.encode(category, forKey: .category)
        try container.encode(stars, forKey: .stars)
        try container.encode(fromSite, forKey: .fromSite)
        try container.encode(fromSiteIcon, forKey: .fromSiteIcon)
        try container.encode(fromSiteUrl, forKey: .fromSiteUrl)
        try container.encode(license, forKey: .license)
        try container.encode(tags, forKey: .tags)
        try container.encode(path, forKey: .path)
        try container.encode(hosted, forKey: .hosted)
        try container.encode(verified, forKey: .verified)
        try container.encode(deployedUrl, forKey: .deployedUrl)
        try container.encode(serverConfig, forKey: .serverConfig)
    }
}

/// One item in a server's `ServerConfig`:
/// `[{"mcpServers": {"name": {"command": ...}}}]`. The inner server object
/// uses the standard `mcpServers` shape, so it reuses the tolerant
/// `MothxMCPMarketRawServer` decoder.
struct MothxModelScopeServerConfig: Codable, Hashable {
    var mcpServers: [String: MothxMCPMarketRawServer] = [:]

    private enum CodingKeys: String, CodingKey { case mcpServers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mcpServers = try container.decodeIfPresent([String: MothxMCPMarketRawServer].self, forKey: .mcpServers) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mcpServers, forKey: .mcpServers)
    }
}

extension MothxModelScopeMCPEntry {
    /// Flattens the first usable `mcpServers` entry into a mothx `mcp.json`
    /// server. When the catalog only hosts the service without publishing a
    /// config (`ServerConfig` empty), falls back to the platform
    /// `DeployedUrl` as a plain http server.
    func makeMCPServer() -> MothxMCPServer? {
        for config in serverConfig {
            for (name, raw) in config.mcpServers {
                if let server = raw.makeMCPServer(name: name) { return server }
            }
        }
        let url = deployedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasPrefix("http") {
            var server = MothxMCPServer()
            server.name = name.isEmpty ? "modelscope-mcp" : name
            server.type = MothxMCPServer.httpType
            server.url = url
            return server
        }
        return nil
    }
}