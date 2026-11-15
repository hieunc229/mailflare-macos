import Foundation
import Observation

/// A remote MCP server the assistant may use: a name, an address and how to prove who is asking.
/// The secret is not part of this record: it lives in the Keychain (`MCPStore`), so the saved
/// list, chat history and anything sent to an AI provider never contain it.
struct MCPServer: Identifiable, Codable, Equatable {
	enum Auth: String, Codable, CaseIterable, Identifiable {
		case none, bearer, header
		var id: String { rawValue }
		var title: String {
			switch self {
			case .none: "None"
			case .bearer: "Bearer token"
			case .header: "Custom header"
			}
		}
	}

	var id = UUID().uuidString
	var name: String
	var url: String
	var auth: Auth = .bearer
	/// The header that carries the secret when `auth` is `.header` (such as `X-API-Key`).
	var headerName = "X-API-Key"
	/// Tools the user chose to run without being asked each time.
	var allowedTools: [String] = []

	var host: String { URL(string: url)?.host ?? url }
}

/// The servers the user connected. Details are JSON in UserDefaults; each secret is a Keychain item
/// under `mcp.<server id>`. Secrets are held in memory only to build request headers.
@MainActor
@Observable
final class MCPStore {
	private static let key = "mcp.servers"

	private(set) var servers: [MCPServer]
	/// Servers pasted into a chat and not saved yet. Their secrets live in memory only, until the user
	/// chooses to save them to MCP credentials.
	private(set) var pending: [MCPServer] = []
	@ObservationIgnored private var secrets: [String: String] = [:]
	@ObservationIgnored private var connections: [String: MCPConnection] = [:]
	/// What each server offers, read once per run of the app (or until its details change).
	@ObservationIgnored private var toolCache: [String: [MCPTool]] = [:]

	init() {
		let defaults = UserDefaults.standard
		servers = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([MCPServer].self, from: $0) } ?? []
		for server in servers { if let secret = AIKeychain.load(Self.account(server.id)) { secrets[server.id] = secret } }
	}

	private static func account(_ id: String) -> String { "mcp.\(id)" }

	private func persist() {
		UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: Self.key)
	}

	/// Saved servers and those added in a chat but not saved yet.
	var allServers: [MCPServer] { servers + pending }
	var hasServers: Bool { !allServers.isEmpty }

	/// Save servers pasted into a chat straight away, without the Save button. Off until the user asks.
	var alwaysSave = UserDefaults.standard.bool(forKey: "mcp.alwaysSave") {
		didSet { UserDefaults.standard.set(alwaysSave, forKey: "mcp.alwaysSave") }
	}

	func secret(for id: String) -> String { secrets[id] ?? "" }

	/// The server the user means by `name`: its name (ignoring case and spacing), its address, or a
	/// name that only one server's name contains. Never a guess between several.
	func server(named name: String) -> MCPServer? {
		let all = allServers
		let wanted = Self.slug(name)
		guard !wanted.isEmpty else { return nil }
		if let exact = all.first(where: { Self.slug($0.name) == wanted }) { return exact }
		if let byAddress = server(matchingURL: name) { return byAddress }
		guard wanted.count >= 3 else { return nil }
		let partial = all.filter { Self.slug($0.name).contains(wanted) }
		return partial.count == 1 ? partial[0] : nil
	}

	/// The server whose address is `text`: the same host, and the same path when `text` has one.
	func server(matchingURL text: String) -> MCPServer? {
		guard let url = URL(string: Self.normalizedURL(text)), let host = url.host?.lowercased() else { return nil }
		let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		return allServers.first { server in
			guard let other = URL(string: Self.normalizedURL(server.url)), other.host?.lowercased() == host else { return false }
			return path.isEmpty || other.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == path
		}
	}

	private static func slug(_ text: String) -> String {
		text.lowercased().filter { $0.isLetter || $0.isNumber }
	}

	// MARK: Validation

	/// The address as a URL, when it is one the app will send a secret to: https, or http only to
	/// this Mac.
	static func validURL(_ text: String) -> URL? {
		guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased() else { return nil }
		switch url.scheme?.lowercased() {
		case "https": return url
		case "http": return ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".localhost") ? url : nil
		default: return nil
		}
	}

	/// An address as typed, with `https://` added when it has no scheme ("store.example.com/api/mcp").
	nonisolated static func normalizedURL(_ text: String) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, !trimmed.contains("://"), trimmed.contains(".") else { return trimmed }
		return "https://" + trimmed
	}

	static func problem(with server: MCPServer, secret: String) -> String? {
		if server.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the server a name." }
		if validURL(server.url) == nil { return "Enter an https:// address (http:// only works for localhost)." }
		if server.auth != .none, secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the token or key." }
		if server.auth == .header, !isHeaderName(server.headerName) { return "Enter a valid header name, such as X-API-Key." }
		return nil
	}

	private static func isHeaderName(_ text: String) -> Bool {
		let name = text.trimmingCharacters(in: .whitespaces)
		return !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
	}

	// MARK: Saving

	/// Adds a server or replaces the one with the same id. An empty `secret` keeps the stored one.
	@discardableResult
	func save(_ server: MCPServer, secret: String) -> String? {
		var server = server
		server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
		server.url = Self.normalizedURL(server.url)
		server.headerName = server.headerName.trimmingCharacters(in: .whitespaces)
		let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
		let effective = trimmed.isEmpty ? self.secret(for: server.id) : trimmed
		if let problem = Self.problem(with: server, secret: effective) { return problem }
		if server.auth == .none {
			secrets[server.id] = nil
			AIKeychain.delete(Self.account(server.id))
		} else if !trimmed.isEmpty {
			guard AIKeychain.save(Self.account(server.id), trimmed) else { return "The Keychain would not store the secret." }
			secrets[server.id] = trimmed
		}
		if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
		connections[server.id] = nil
		toolCache[server.id] = nil
		persist()
		return nil
	}

	func remove(_ id: String) {
		servers.removeAll { $0.id == id }
		secrets[id] = nil
		connections[id] = nil
		toolCache[id] = nil
		AIKeychain.delete(Self.account(id))
		persist()
	}

	/// A server found in a chat message, held for that chat until the user saves it.
	struct Added { var server: MCPServer; var note: String; var isNew: Bool }

	/// Takes servers read from pasted text into the chat without saving them: each gets a name (the
	/// one given, else one made from its address, never one another server has), and its secret stays
	/// in memory. A server already known by address is reused, not added twice.
	func addPending(_ candidates: [MCPCandidate]) -> (added: [Added], errors: [String]) {
		var added: [Added] = [], errors: [String] = []
		for candidate in candidates {
			let url = Self.normalizedURL(candidate.url)
			if let known = server(matchingURL: url) {
				if pending.contains(where: { $0.id == known.id }), !candidate.secret.isEmpty { secrets[known.id] = candidate.secret; connections[known.id] = nil }
				added.append(Added(server: known, note: "“\(known.name)” (\(known.host)) is already here; using it.", isNew: false))
				continue
			}
			var server = MCPServer(name: uniqueName(candidate.name, host: URL(string: url)?.host), url: url)
			server.auth = candidate.auth
			if candidate.auth == .header { server.headerName = candidate.headerName }
			if let problem = Self.problem(with: server, secret: candidate.secret) {
				errors.append("Could not add “\(candidate.name)”: \(problem)")
				continue
			}
			pending.append(server)
			if server.auth != .none { secrets[server.id] = candidate.secret }
			added.append(Added(server: server, note: "Added “\(server.name)” (\(server.host)).", isNew: true))
		}
		return (added, errors)
	}

	private func uniqueName(_ name: String, host: String?) -> String {
		let taken = Set(allServers.map { Self.slug($0.name) })
		let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "MCP Server" : name.trimmingCharacters(in: .whitespacesAndNewlines)
		if !taken.contains(Self.slug(base)) { return base }
		if let host, !taken.contains(Self.slug("\(base) (\(host))")) { return "\(base) (\(host))" }
		var n = 2
		while taken.contains(Self.slug("\(base) \(n)")) { n += 1 }
		return "\(base) \(n)"
	}

	/// Saves a server added in a chat to MCP credentials (its secret goes to the Keychain). Returns a
	/// problem to show, or nil.
	func promote(_ id: String) -> String? {
		guard let server = pending.first(where: { $0.id == id }) else { return "This server is no longer waiting to be saved. Paste its details again." }
		if let problem = save(server, secret: secret(for: id)) { return problem }
		pending.removeAll { $0.id == id }
		return nil
	}

	func isSaved(_ id: String) -> Bool { servers.contains { $0.id == id } }
	func isPending(_ id: String) -> Bool { pending.contains { $0.id == id } }

	// MARK: Allowing tools

	func isAllowed(tool: String, on server: MCPServer) -> Bool { server.allowedTools.contains(tool) }

	func allow(tool: String, on id: String) {
		guard let index = servers.firstIndex(where: { $0.id == id }), !servers[index].allowedTools.contains(tool) else { return }
		servers[index].allowedTools.append(tool)
		persist()
	}

	func forgetApprovals(for id: String) {
		guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
		servers[index].allowedTools = []
		persist()
	}

	// MARK: Talking to a server

	static func headers(for server: MCPServer, secret: String) -> [String: String] {
		let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
		switch server.auth {
		case .none: return [:]
		case .bearer:
			let token = value.lowercased().hasPrefix("bearer ") ? String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) : value
			return ["Authorization": "Bearer \(token)"]
		case .header: return [server.headerName.trimmingCharacters(in: .whitespaces): value]
		}
	}

	private func connection(for server: MCPServer) throws -> MCPConnection {
		if let existing = connections[server.id] { return existing }
		guard let url = Self.validURL(server.url) else { throw AIError(message: "“\(server.name)” has no valid https:// address.") }
		let made = MCPConnection(url: url, headers: Self.headers(for: server, secret: secret(for: server.id)))
		connections[server.id] = made
		return made
	}

	func tools(of server: MCPServer, refresh: Bool = false) async throws -> [MCPTool] {
		if !refresh, let cached = toolCache[server.id] { return cached }
		let list = try await connection(for: server).listTools()
		toolCache[server.id] = list
		return list
	}

	/// The tools read earlier, without asking the server.
	func cachedTool(_ name: String, of server: MCPServer) -> MCPTool? {
		toolCache[server.id]?.first { $0.name == name }
	}

	func call(_ tool: String, arguments: [String: Any], on server: MCPServer) async throws -> MCPToolResult {
		try await connection(for: server).callTool(tool, arguments: arguments)
	}

	/// Tries details that are not saved yet: connects, and lists what the server offers.
	static func test(_ server: MCPServer, secret: String) async throws -> [MCPTool] {
		guard let url = validURL(server.url) else { throw AIError(message: "Enter an https:// address.") }
		return try await MCPConnection(url: url, headers: headers(for: server, secret: secret)).listTools()
	}
}

// MARK: - Reading credentials from pasted text

/// Credentials found in text, ready to save.
struct MCPCandidate {
	var name: String
	var url: String
	var auth: MCPServer.Auth
	var headerName: String
	var secret: String
}

/// Finds MCP server details in text the user pasted into the chat, so the secret can be kept in the
/// Keychain and never reach the AI provider. Understands the `mcpServers` JSON that MCP clients
/// share, a bare `{url, headers}` object, and `Key: value` lines (name, url, token, Authorization,
/// a header such as X-API-Key). Text without both an address and a secret is left alone.
enum MCPCredentialParser {
	struct Result {
		var candidates: [MCPCandidate] = []
		/// The text with every secret hidden, as the chat shows it.
		var redacted: String
		/// What is left once the credentials are taken out: the user's actual request, if any.
		var rest: String
	}

	static func parse(_ text: String) -> Result {
		var result = Result(redacted: text, rest: text)
		if let json = fromJSON(text) {
			result.candidates = json.candidates
			result.rest = text.replacingCharacters(in: json.range, with: "")
		} else if let lines = fromLines(text) {
			result.candidates = lines.candidates
			result.rest = lines.rest
		} else if let free = fromFreeText(text) {
			result.candidates = free.candidates
			result.rest = free.rest
		}
		guard !result.candidates.isEmpty else { return result }
		for secret in Set(result.candidates.map(\.secret)) where secret.count >= 4 {
			result.redacted = result.redacted.replacingOccurrences(of: secret, with: "••••••")
		}
		result.rest = result.rest.trimmingCharacters(in: .whitespacesAndNewlines)
		return result
	}

	/// A server address given with no secret ("connect https://mcp.example.com/sse"): only when the
	/// text speaks of MCP, so an ordinary link in a message is never taken for a server.
	@MainActor static func urlOnly(_ text: String) -> (candidate: MCPCandidate, rest: String)? {
		guard text.range(of: "mcp", options: .caseInsensitive) != nil,
			  let range = text.range(of: "https?://[^\\s,;)\"'`>]+", options: [.regularExpression, .caseInsensitive]) else { return nil }
		let url = cleanURL(String(text[range]))
		guard MCPStore.validURL(url) != nil else { return nil }
		var rest = text
		rest.removeSubrange(range)
		let candidate = MCPCandidate(name: nameFromHost(url), url: url, auth: .none, headerName: "X-API-Key", secret: "")
		return (candidate, rest.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	/// True when `rest` holds a request of its own and not only leftover punctuation.
	static func hasRequest(_ rest: String) -> Bool {
		rest.split(whereSeparator: { !$0.isLetter }).filter { $0.count > 1 }.count >= 3
	}

	// MARK: JSON

	private static func fromJSON(_ text: String) -> (candidates: [MCPCandidate], range: Range<String.Index>)? {
		guard let start = text.firstIndex(of: "{"), let end = matchingBrace(in: text, from: start) else { return nil }
		let range = start..<text.index(after: end)
		guard let data = String(text[range]).data(using: .utf8),
			  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
		var found: [MCPCandidate] = []
		for key in ["mcpServers", "servers", "mcp"] {
			if let table = object[key] as? [String: Any] {
				for (name, value) in table.sorted(by: { $0.key < $1.key }) {
					if let entry = value as? [String: Any], let candidate = candidate(from: entry, name: name) { found.append(candidate) }
				}
			}
		}
		if found.isEmpty, let candidate = candidate(from: object, name: object["name"] as? String) { found = [candidate] }
		return found.isEmpty ? nil : (found, range)
	}

	/// The closing brace of the object that opens at `start`, skipping braces inside strings.
	private static func matchingBrace(in text: String, from start: String.Index) -> String.Index? {
		var depth = 0, inString = false, escaped = false
		var index = start
		while index < text.endIndex {
			let c = text[index]
			if inString {
				if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
			} else if c == "\"" { inString = true }
			else if c == "{" { depth += 1 }
			else if c == "}" { depth -= 1; if depth == 0 { return index } }
			index = text.index(after: index)
		}
		return nil
	}

	private static func candidate(from entry: [String: Any], name: String?) -> MCPCandidate? {
		guard let url = (["url", "serverUrl", "server_url", "endpoint", "baseUrl", "httpUrl"].compactMap { entry[$0] as? String }.first) else { return nil }
		var auth = MCPServer.Auth.bearer
		var headerName = "X-API-Key"
		var secret: String?
		if let headers = entry["headers"] as? [String: Any] {
			if let value = headers.first(where: { $0.key.lowercased() == "authorization" })?.value as? String {
				if value.lowercased().hasPrefix("bearer ") { secret = String(value.dropFirst(7)) } else { auth = .header; headerName = "Authorization"; secret = value }
			} else if let pair = headers.first(where: { !["content-type", "accept"].contains($0.key.lowercased()) && $0.value is String }) {
				auth = .header; headerName = pair.key; secret = pair.value as? String
			}
		}
		if secret == nil {
			secret = ["token", "apiKey", "api_key", "key", "secret", "bearer", "accessToken", "access_token"].compactMap { entry[$0] as? String }.first
		}
		guard let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty, !secret.contains("•") else { return nil }
		let clean = MCPStore.normalizedURL(cleanURL(url))
		return MCPCandidate(name: (name?.isEmpty == false ? name! : nameFromHost(clean)), url: clean, auth: auth, headerName: headerName, secret: secret)
	}

	// MARK: Lines

	private static func fromLines(_ text: String) -> (candidates: [MCPCandidate], rest: String)? {
		var name: String?, url: String?, secret: String?, headerName: String?
		var auth = MCPServer.Auth.bearer
		var keep: [String] = []
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			// "Authorization: Bearer abc", "token = abc", "X-API-Key: abc"
			if let split = trimmed.firstIndex(where: { $0 == ":" || $0 == "=" }) {
				let rawKey = String(trimmed[..<split]).trimmingCharacters(in: .whitespaces)
				let value = String(trimmed[trimmed.index(after: split)...]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'`,")))
				let key = rawKey.lowercased().filter { $0.isLetter || $0.isNumber }
				// "https://…" has a colon too: that line is a bare address, handled below.
				let lower = trimmed.lowercased()
				let isBareURL = lower.hasPrefix("http://") || lower.hasPrefix("https://")
				if !isBareURL, !value.isEmpty, rawKey.count <= 40 {
					switch key {
					case "name", "server", "servername", "label", "title", "mcpname":
						name = value; continue
					case "url", "serverurl", "mcpurl", "mcpserverurl", "endpoint", "baseurl", "address", "mcpendpoint":
						url = value; continue
					case "authorization":
						if value.lowercased().hasPrefix("bearer ") { secret = String(value.dropFirst(7)) } else { auth = .header; headerName = "Authorization"; secret = value }
						continue
					case "token", "apikey", "key", "secret", "bearer", "bearertoken", "accesstoken", "authtoken", "apisecret", "mcptoken", "mcpkey", "credential", "credentials":
						secret = value; continue
					case "header", "headername":
						headerName = value; auth = .header; continue
					default:
						// A header named like a key: X-API-Key, X-Auth-Token.
						if rawKey.contains("-"), ["key", "token", "auth", "secret"].contains(where: { key.contains($0) }) {
							auth = .header; headerName = rawKey; secret = value; continue
						}
					}
				}
			}
			if trimmed.lowercased().hasPrefix("bearer "), secret == nil {
				secret = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces); continue
			}
			if url == nil, let found = trimmed.range(of: "^https?://\\S+$", options: [.regularExpression, .caseInsensitive]) {
				url = String(trimmed[found]); continue
			}
			keep.append(line)
		}
		// A header name given on its own line applies to the key found.
		// A hidden secret ("••••••", as the chat shows one already saved) is not a secret to save.
		guard let url, let secret, !secret.isEmpty, !secret.contains("•") else { return nil }
		let clean = MCPStore.normalizedURL(cleanURL(url))
		let candidate = MCPCandidate(name: name ?? nameFromHost(clean), url: clean, auth: auth, headerName: headerName ?? "X-API-Key", secret: secret)
		return ([candidate], keep.joined(separator: "\n"))
	}

	// MARK: Free text

	/// A secret that stands out by its shape: a prefixed key with digits (`caf_…`, `sk_live_…`), a
	/// `Bearer` value, or a long mixed-case run of letters and digits.
	private static let secretShapes = [
		"\\b[A-Za-z]{2,8}_(?=[A-Za-z0-9_\\-]*\\d)[A-Za-z0-9][A-Za-z0-9_\\-]{15,}\\b",
		"(?<=Bearer )[A-Za-z0-9._~+/=\\-]{12,}",
		"\\b(?=[A-Za-z0-9_\\-]*\\d)(?=[A-Za-z0-9_\\-]*[a-z])(?=[A-Za-z0-9_\\-]*[A-Z])[A-Za-z0-9_\\-]{32,}\\b",
	]

	private static func ranges(of pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [Range<String.Index>] {
		guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
		return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
	}

	/// The first match of `pattern`, with its first capture group.
	private static func firstMatch(_ pattern: String, in text: String) -> (full: Range<String.Index>, group: String)? {
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
			  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
			  let full = Range(match.range, in: text), let group = Range(match.range(at: 1), in: text) else { return nil }
		return (full, String(text[group]))
	}

	/// Whether the text holds something shaped like a secret, which should not go to an AI provider.
	static func looksLikeSecret(_ text: String) -> Bool {
		secretShapes.contains { !ranges(of: $0, in: text).isEmpty }
	}

	/// The text with anything shaped like a secret hidden.
	static func hidingSecrets(in text: String) -> String {
		var result = text
		for pattern in secretShapes {
			for range in ranges(of: pattern, in: result).reversed() { result.replaceSubrange(range, with: "••••••") }
		}
		return result
	}

	/// Details written as a sentence: "(token) caf_…, (endpoint) store.example.com/api/mcp". The label
	/// words, `:`/`=`/"is", brackets and a missing `https://` are all tolerated.
	private static func fromFreeText(_ text: String) -> (candidates: [MCPCandidate], rest: String)? {
		var used: [Range<String.Index>] = []

		var secret: String?
		let labeledSecret = "\\(?\\b(?:api[ _-]?key|access[ _-]?token|auth[ _-]?token|bearer(?:[ _-]?token)?|token|secret|key)\\b\\)?\\s*(?:[:=]|\\bis\\b)?\\s*[\"'`]?((?=[A-Za-z0-9._~+/=\\-]*[\\d_\\-])[A-Za-z0-9][A-Za-z0-9._~+/=\\-]{7,})"
		if let found = firstMatch(labeledSecret, in: text) {
			secret = found.group; used.append(found.full)
		} else {
			let shaped = secretShapes.flatMap { ranges(of: $0, in: text) }
			if shaped.count == 1 { secret = String(text[shaped[0]]); used.append(shaped[0]) }
		}

		var address: String?
		let host = "[A-Za-z0-9][A-Za-z0-9.\\-]*\\.[A-Za-z]{2,}(?::\\d+)?(?:/[^\\s,;)\"'`>]*)?"
		let labeledURL = "\\(?\\b(?:endpoint|url|server|address|mcp(?:[ _-]?(?:url|server|endpoint))?)\\b\\)?\\s*(?:[:=]|\\bis\\b)?\\s*[\"'`<]?((?:https?://)?" + host + ")"
		if let found = firstMatch(labeledURL, in: text) {
			address = found.group; used.append(found.full)
		} else if let scheme = ranges(of: "https?://[^\\s,;)\"'`>]+", in: text, options: [.caseInsensitive]).first {
			address = String(text[scheme]); used.append(scheme)
		} else if let bare = ranges(of: "(?<![@\\w.\\-/])[A-Za-z0-9][A-Za-z0-9\\-]*(?:\\.[A-Za-z0-9\\-]+)+/[^\\s,;)\"'`>]+", in: text).first {
			address = String(text[bare]); used.append(bare)
		}

		guard let secret, let address else { return nil }
		var url = cleanURL(address)
		while url.hasSuffix(".") { url.removeLast() }
		if !url.lowercased().hasPrefix("http") { url = "https://" + url }

		var rest = text
		for range in used.sorted(by: { $0.lowerBound > $1.lowerBound }) { rest.removeSubrange(range) }
		for (pattern, replacement) in [
			("(?i)connect(?: me)?(?: to)?(?: this| the)?\\s+mcp(?: server)?\\s*:?", ""),
			("\\(\\s*\\)", ""), ("\\s*,(\\s*,)+", ","), ("^[\\s,;:.\\-]+", ""), ("[ \\t]{2,}", " "),
		] {
			rest = rest.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
		}
		let candidate = MCPCandidate(name: nameFromHost(url), url: url, auth: .bearer, headerName: "X-API-Key", secret: secret)
		return ([candidate], rest)
	}

	// MARK: Names

	private static func cleanURL(_ text: String) -> String {
		text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`<>,;")))
	}

	/// "https://mcp.paymug.com/v1" → "Paymug".
	static func nameFromHost(_ url: String) -> String {
		guard var host = URL(string: url)?.host?.lowercased() else { return "MCP Server" }
		for prefix in ["www.", "mcp.", "api.", "app."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
		let labels = host.split(separator: ".")
		let base = labels.count >= 2 ? String(labels[labels.count - 2]) : String(labels.first ?? "mcp")
		return base.prefix(1).uppercased() + base.dropFirst()
	}
}
