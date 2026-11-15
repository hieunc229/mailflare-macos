import Foundation

/// One tool an MCP server offers.
struct MCPTool {
	var name: String
	var description: String
	var inputSchema: [String: Any]
	/// The server's own claim (`annotations.readOnlyHint`) that the tool changes nothing.
	var readOnly: Bool
}

struct MCPToolResult {
	var text: String
	var isError: Bool
}

/// Refuses redirects: a secret sent in a header must only ever go to the address the user saved.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
	func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
					newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
		completionHandler(nil)
	}
}

/// A client for an MCP server over streamable HTTP (JSON-RPC 2.0 by POST; the server answers with
/// JSON or a short event stream). Connections use no cookies and no cache, never follow redirects,
/// and never log what they send.
actor MCPConnection {
	private static let maxBytes = 4_000_000
	/// What a tool result may hold before it is cut, so one answer cannot fill the model's context.
	private static let maxResultCharacters = 30_000

	private let url: URL
	private let headers: [String: String]
	private let session: URLSession
	private var sessionID: String?
	private var protocolVersion = "2025-03-26"
	private var ready = false
	private var counter = 0

	private struct SessionExpired: Error {}

	init(url: URL, headers: [String: String]) {
		self.url = url
		self.headers = headers
		session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
	}

	// MARK: Requests

	func listTools() async throws -> [MCPTool] {
		var tools: [MCPTool] = []
		var cursor: String?
		for _ in 0..<5 {
			var params: [String: Any] = [:]
			if let cursor { params["cursor"] = cursor }
			let result = try await request("tools/list", params)
			for item in (result["tools"] as? [[String: Any]]) ?? [] {
				guard let name = item["name"] as? String else { continue }
				let annotations = item["annotations"] as? [String: Any]
				tools.append(MCPTool(
					name: name, description: (item["description"] as? String) ?? "",
					inputSchema: (item["inputSchema"] as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()],
					readOnly: (annotations?["readOnlyHint"] as? Bool) == true))
			}
			cursor = result["nextCursor"] as? String
			if cursor == nil { break }
		}
		return tools
	}

	func callTool(_ name: String, arguments: [String: Any]) async throws -> MCPToolResult {
		let result = try await request("tools/call", ["name": name, "arguments": arguments])
		var parts: [String] = []
		for item in (result["content"] as? [[String: Any]]) ?? [] {
			switch item["type"] as? String {
			case "text": if let text = item["text"] as? String { parts.append(text) }
			case "resource": if let text = (item["resource"] as? [String: Any])?["text"] as? String { parts.append(text) }
			case let other?: parts.append("[\(other) content not shown]")
			default: break
			}
		}
		if parts.isEmpty, let structured = result["structuredContent"],
		   JSONSerialization.isValidJSONObject(structured), let data = try? JSONSerialization.data(withJSONObject: structured) {
			parts.append(String(decoding: data, as: UTF8.self))
		}
		var text = parts.joined(separator: "\n")
		if text.count > Self.maxResultCharacters { text = String(text.prefix(Self.maxResultCharacters)) + "\n… [truncated]" }
		return MCPToolResult(text: text, isError: (result["isError"] as? Bool) == true)
	}

	/// One JSON-RPC call: starts the session first when needed, and once more if the server forgot it.
	private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
		for attempt in 0..<2 {
			do {
				try await start()
				let id = nextID()
				let reply = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params], id: id)
				if let error = reply?["error"] as? [String: Any] {
					throw AIError(message: (error["message"] as? String) ?? "The MCP server returned an error.")
				}
				return (reply?["result"] as? [String: Any]) ?? [:]
			} catch is SessionExpired {
				ready = false; sessionID = nil
				if attempt == 1 { throw AIError(message: "The MCP server keeps ending the session.") }
			}
		}
		throw AIError(message: "The MCP server did not answer.")
	}

	private func nextID() -> Int { counter += 1; return counter }

	private func start() async throws {
		guard !ready else { return }
		let id = nextID()
		let reply = try await post([
			"jsonrpc": "2.0", "id": id, "method": "initialize",
			"params": ["protocolVersion": protocolVersion, "capabilities": [String: Any](), "clientInfo": ["name": "Mailflare", "version": "1"]],
		], id: id)
		if let error = reply?["error"] as? [String: Any] {
			throw AIError(message: (error["message"] as? String) ?? "The MCP server refused to start a session.")
		}
		if let version = (reply?["result"] as? [String: Any])?["protocolVersion"] as? String { protocolVersion = version }
		ready = true
		_ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], id: nil)
	}

	/// Posts one message. With an `id`, returns the matching JSON-RPC reply; without, just checks the
	/// server accepted it.
	private func post(_ body: [String: Any], id: Int?) async throws -> [String: Any]? {
		var request = URLRequest(url: url, timeoutInterval: 60)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
		for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
		if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
		if ready { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
		request.httpBody = try JSONSerialization.data(withJSONObject: body)

		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse else { throw AIError(message: "The MCP server did not answer.") }
		if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty { sessionID = sid }
		switch http.statusCode {
		case 200..<300: break
		case 401, 403: throw AIError(message: "The MCP server rejected the credentials (status \(http.statusCode)).")
		case 300..<400: throw AIError(message: "The MCP server redirected the request. Use its final address; credentials are never sent to a redirect.")
		case 404 where sessionID != nil && ready: throw SessionExpired()
		default:
			let detail = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
			throw AIError(message: "The MCP server answered with status \(http.statusCode)." + (detail.isEmpty ? "" : " \(detail)"))
		}
		guard let id else { return nil }
		guard data.count <= Self.maxBytes else { throw AIError(message: "The MCP server's answer is too large.") }
		let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
		let messages: [[String: Any]] = type.contains("text/event-stream") ? Self.events(in: data) : Self.messages(in: data)
		guard let reply = messages.first(where: { ($0["id"] as? Int) == id }) else {
			throw AIError(message: "The MCP server sent no answer to the request.")
		}
		return reply
	}

	/// The JSON-RPC messages in a JSON body (one object, or a batch).
	private static func messages(in data: Data) -> [[String: Any]] {
		let object = try? JSONSerialization.jsonObject(with: data)
		if let list = object as? [[String: Any]] { return list }
		return (object as? [String: Any]).map { [$0] } ?? []
	}

	/// The JSON-RPC messages carried in `data:` lines of an event stream.
	private static func events(in data: Data) -> [[String: Any]] {
		var found: [[String: Any]] = []
		var buffer: [String] = []
		func flush() {
			defer { buffer = [] }
			guard !buffer.isEmpty, let payload = buffer.joined(separator: "\n").data(using: .utf8) else { return }
			found += messages(in: payload)
		}
		for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
			let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
			if line.isEmpty { flush() } else if line.hasPrefix("data:") { buffer.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
		}
		flush()
		return found
	}
}
