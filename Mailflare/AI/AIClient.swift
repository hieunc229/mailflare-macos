import Foundation

struct AIToolCall {
	var id: String
	var name: String
	var arguments: String
}

enum AIStreamEvent {
	case text(String)
	/// Sent once, after the text, when the model asked for tools.
	case toolCalls([AIToolCall])
}

struct AIError: LocalizedError {
	let message: String
	var errorDescription: String? { message }
}

/// A streaming client for the OpenAI chat-completions protocol.
struct AIClient {
	var baseURL: URL
	var apiKey: String
	var model: String

	private static func request(_ url: URL, apiKey: String) -> URLRequest {
		var request = URLRequest(url: url)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
		return request
	}

	static func listModels(baseURL: URL, apiKey: String) async throws -> [String] {
		var request = request(baseURL.appendingPathComponent("models"), apiKey: apiKey)
		// Anthropic lists models through its own API, not the OpenAI-compatible one, which requires
		// a version header and returns 20 models per page unless asked for more.
		if baseURL.host == "api.anthropic.com" {
			request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
			request.url?.append(queryItems: [URLQueryItem(name: "limit", value: "1000")])
		}
		request.timeoutInterval = 15
		let (data, response) = try await URLSession.shared.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard status == 200 else { throw AIError(message: errorMessage(status: status, body: String(decoding: data, as: UTF8.self))) }
		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		let items = (json?["data"] as? [[String: Any]]) ?? (json?["models"] as? [[String: Any]]) ?? []
		return items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
	}

	/// Streams one assistant turn. `messages` and `tools` are in the protocol's own JSON shape.
	func stream(messages: [[String: Any]], tools: [[String: Any]]) -> AsyncThrowingStream<AIStreamEvent, Error> {
		var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
		// Some providers reject an empty tool list.
		if !tools.isEmpty { body["tools"] = tools }
		let url = baseURL.appendingPathComponent("chat/completions")
		let apiKey = apiKey
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					var request = Self.request(url, apiKey: apiKey)
					request.httpMethod = "POST"
					request.timeoutInterval = 120
					request.httpBody = try JSONSerialization.data(withJSONObject: body)
					let (bytes, response) = try await URLSession.shared.bytes(for: request)
					let status = (response as? HTTPURLResponse)?.statusCode ?? 0
					guard status == 200 else {
						var text = ""
						for try await line in bytes.lines { text += line; if text.count > 2_000 { break } }
						throw AIError(message: Self.errorMessage(status: status, body: text))
					}
					var calls: [Int: AIToolCall] = [:]
					for try await line in bytes.lines {
						guard line.hasPrefix("data:") else { continue }
						let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
						if payload == "[DONE]" { break }
						guard let data = payload.data(using: .utf8),
							  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
						// A provider can fail after the stream has started, with an error event.
						if object["error"] != nil, let message = Self.errorText(object) { throw AIError(message: message) }
						guard let delta = ((object["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] else { continue }
						if let text = delta["content"] as? String, !text.isEmpty { continuation.yield(.text(text)) }
						for call in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
							let index = call["index"] as? Int ?? 0
							var entry = calls[index] ?? AIToolCall(id: "", name: "", arguments: "")
							if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
							if let function = call["function"] as? [String: Any] {
								if let name = function["name"] as? String, entry.name.isEmpty { entry.name = name }
								if let arguments = function["arguments"] as? String { entry.arguments += arguments }
							}
							calls[index] = entry
						}
					}
					if !calls.isEmpty {
						let list = calls.sorted { $0.key < $1.key }.map { pair -> AIToolCall in
							var call = pair.value
							if call.id.isEmpty { call.id = "call_" + UUID().uuidString.prefix(8).lowercased() }
							return call
						}
						continuation.yield(.toolCalls(list))
					}
					continuation.finish()
				} catch is CancellationError {
					continuation.finish()
				} catch let error as URLError where error.code == .cancelled {
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// The provider's own message when it sent one, else a line for the status.
	static func errorMessage(status: Int, body: String) -> String {
		if let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
			if let message = errorText(json) { return message }
		}
		switch status {
		case 401, 403: return "The provider rejected the API key."
		case 404: return "The provider does not know this model or address."
		case 429: return "The provider is rate limiting requests. Try again shortly."
		default: return "The provider answered with status \(status)."
		}
	}

	/// Reads `{"error": ...}` bodies and in-stream error events. OpenRouter wraps the real reason in
	/// `error.metadata`: its own message is only "Provider returned error", while `metadata.raw` holds
	/// what the upstream provider said and `provider_name` who said it.
	static func errorText(_ json: [String: Any]) -> String? {
		if let text = json["error"] as? String { return text }
		if let error = json["error"] as? [String: Any] {
			var parts: [String] = []
			if let message = error["message"] as? String, !message.isEmpty { parts.append(message) }
			if let metadata = error["metadata"] as? [String: Any] {
				var detail = rawDetail(metadata["raw"])
				if detail == nil, let reasons = metadata["reasons"] as? [String], !reasons.isEmpty { detail = "Flagged: " + reasons.joined(separator: ", ") }
				if let detail {
					let who = (metadata["provider_name"] as? String).map { "\($0): " } ?? ""
					parts.append(who + detail)
				}
			}
			if parts.isEmpty, let code = error["code"] { parts.append("Error \(code)") }
			if !parts.isEmpty { return parts.joined(separator: ". ") }
		}
		return json["message"] as? String
	}

	/// The text inside an upstream error: a string, possibly JSON with its own message.
	private static func rawDetail(_ raw: Any?) -> String? {
		func message(in object: [String: Any]) -> String? {
			if let error = object["error"] as? [String: Any] { return (error["message"] as? String) ?? (error["detail"] as? String) }
			if let error = object["error"] as? String { return error }
			return (object["message"] as? String) ?? (object["detail"] as? String)
		}
		if let object = raw as? [String: Any] { return message(in: object) }
		guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
		if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		   let found = message(in: object) { return found }
		return text.count > 400 ? String(text.prefix(400)) + "…" : text
	}
}
