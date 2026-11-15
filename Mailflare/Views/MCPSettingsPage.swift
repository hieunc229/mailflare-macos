import SwiftUI

/// Settings → MCP Credentials: the remote MCP servers the assistant may use. Each has a name, an
/// address and, usually, a token or key. The secret is stored in the Keychain; this page never shows
/// it again once saved.
struct MCPSettingsPage: View {
	@Environment(MailStore.self) private var store
	@State private var editing: MCPServer?
	@State private var editingIsNew = false
	@State private var secret = ""

	private var mcp: MCPStore { store.mcp }

	var body: some View {
		SettingsGroup(
			title: "MCP Servers",
			footer: "The assistant uses these servers to look things up and act in other services. Tokens and keys are stored in your Keychain on this Mac and are never sent to the AI provider. You can also paste credentials into the assistant chat. The assistant asks before it runs a tool that could change data."
		) {
			SettingsRow {
				VStack(alignment: .leading, spacing: 2) {
					Text("Always save MCP credentials").font(Typography.body)
					Text("Save servers pasted into the assistant without asking.").font(Typography.meta).foregroundStyle(.secondary)
				}
				Spacer(minLength: 8)
				Toggle("", isOn: Binding(get: { mcp.alwaysSave }, set: { mcp.alwaysSave = $0 })).labelsHidden().toggleStyle(.switch)
			}
			SettingsDivider()
			if mcp.servers.isEmpty {
				SettingsRow {
					Text("No servers yet").font(Typography.body).foregroundStyle(.secondary)
					Spacer()
				}
			}
			ForEach(Array(mcp.servers.enumerated()), id: \.element.id) { index, server in
				if index > 0 { SettingsDivider() }
				SettingsRow {
					VStack(alignment: .leading, spacing: 1) {
						Text(server.name).font(Typography.bodySemibold).lineLimit(1)
						Text("\(server.host) · \(server.auth.title)").font(Typography.meta).foregroundStyle(.secondary).lineLimit(1)
					}
					Spacer(minLength: 8)
					Button("Edit") { edit(server, isNew: false) }.buttonStyle(.pill)
					Button("Remove") { if editing?.id == server.id { editing = nil }; mcp.remove(server.id) }.buttonStyle(.pill)
				}
			}
		}
		WideButton(title: "Add MCP Server", icon: .add) { edit(MCPServer(name: "", url: ""), isNew: true) }
			.sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
				MCPServerEditor(server: Binding(get: { editing ?? MCPServer(name: "", url: "") }, set: { editing = $0 }),
								secret: $secret, isNew: editingIsNew) {
					editing = nil
				}
			}
	}

	private func edit(_ server: MCPServer, isNew: Bool) {
		// A saved secret is never put back on screen: leaving the field empty keeps it.
		secret = ""
		editingIsNew = isNew
		editing = server
	}
}

/// The form for one server: its name, address and how it checks who is asking.
private struct MCPServerEditor: View {
	@Environment(MailStore.self) private var store
	@Binding var server: MCPServer
	@Binding var secret: String
	var isNew: Bool
	var close: () -> Void

	@State private var testing = false
	@State private var message: String?
	@State private var messageIsError = false

	private var hasSavedSecret: Bool { !store.mcp.secret(for: server.id).isEmpty }
	private var effectiveSecret: String { secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? store.mcp.secret(for: server.id) : secret }
	private var problem: String? { MCPStore.problem(with: server, secret: effectiveSecret) }

	var body: some View {
		ModalScaffold(title: isNew ? "New MCP Server" : "Edit MCP Server", width: 460) {
			VStack(alignment: .leading, spacing: 12) {
				SettingsGroup(title: "Server") {
					SettingsRow {
						Text("Name").font(Typography.body)
						Spacer(minLength: 12)
						TextField("Paymug", text: $server.name)
							.textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Typography.body)
					}
					SettingsDivider()
					SettingsRow {
						Text("URL").font(Typography.body)
						Spacer(minLength: 12)
						TextField("https://mcp.example.com/mcp", text: $server.url)
							.textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Typography.body)
							.autocorrectionDisabled()
					}
					SettingsDivider()
					SettingsPicker(
						title: "Authorization",
						options: MCPServer.Auth.allCases.map { ($0.title, $0) },
						selection: $server.auth)
					if server.auth == .header {
						SettingsDivider()
						SettingsRow {
							Text("Header").font(Typography.body)
							Spacer(minLength: 12)
							TextField("X-API-Key", text: $server.headerName)
								.textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Typography.body)
								.autocorrectionDisabled()
						}
					}
					if server.auth != .none {
						SettingsDivider()
						SettingsRow {
							Text(server.auth == .bearer ? "Token" : "Value").font(Typography.body)
							Spacer(minLength: 12)
							SecureField(hasSavedSecret ? "Saved in Keychain — leave empty to keep" : "Paste the token or key", text: $secret)
								.textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Typography.body)
						}
					}
				}
				if let message {
					Text(message).font(Typography.meta).foregroundStyle(messageIsError ? Color.orange : Color.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				if !server.allowedTools.isEmpty {
					HStack {
						Text("Always allowed: \(server.allowedTools.joined(separator: ", "))")
							.font(Typography.meta).foregroundStyle(.secondary).lineLimit(2)
						Spacer(minLength: 8)
						Button("Reset") {
							store.mcp.forgetApprovals(for: server.id)
							server.allowedTools = []
						}.buttonStyle(.pill)
					}
				}
			}
			.frame(minHeight: 300, alignment: .top)
		} footer: {
			HStack(spacing: 8) {
				Button { Task { await test() } } label: {
					if testing { ProgressView().controlSize(.small) } else { Text("Test Connection") }
				}
				.buttonStyle(.pill).disabled(testing || problem != nil)
				Spacer()
				Button("Cancel", action: close).buttonStyle(.pill).keyboardShortcut(.cancelAction)
				Button("Save", action: save).buttonStyle(.pillProminent).disabled(problem != nil)
			}
		}
	}

	private func save() {
		if let failure = store.mcp.save(server, secret: secret) {
			message = failure; messageIsError = true
			return
		}
		secret = ""
		close()
	}

	private func test() async {
		testing = true; message = nil
		defer { testing = false }
		do {
			let tools = try await MCPStore.test(server, secret: effectiveSecret)
			messageIsError = false
			let names = tools.prefix(6).map(\.name).joined(separator: ", ")
			message = tools.isEmpty ? "Connected. The server lists no tools." : "Connected. \(tools.count) tool\(tools.count == 1 ? "" : "s"): \(names)\(tools.count > 6 ? "…" : "")"
		} catch {
			messageIsError = true
			message = error.localizedDescription
		}
	}
}
