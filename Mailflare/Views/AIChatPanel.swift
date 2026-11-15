import SwiftUI

/// The assistant, as a card on the window's trailing edge. The sparkles button in the title bar
/// opens and closes it; it only exists once an AI provider is set up.
struct AIChatPanel: View {
	static let width: CGFloat = 360
	/// The panel's width: its usual one, or the window's when it is expanded.
	var panelWidth: CGFloat = AIChatPanel.width
	/// Past this, the conversation and the message box stay in a centred column, so lines stay readable.
	private static let readableWidth: CGFloat = 760

	@Environment(MailStore.self) private var store
	@State private var input = ""
	@State private var attachments: [ChatAttachment] = []
	@State private var attachError: String?
	@State private var dropTargeted = false
	@State private var modelOpen = false
	@State private var modelQuery = ""
	/// The provider whose models the dropdown is showing, when there are several.
	@State private var modelProvider: String?
	@State private var focusRequest = 0
	@State private var inputHeight: CGFloat = 20
	/// Setting it to true puts the cursor in the message box.
	private var focused: Bool {
		get { false }
		nonmutating set { if newValue { focusRequest &+= 1 } }
	}
	/// The turn the pointer is over, by the id of its last message: the one that carries the time and
	/// the buttons, wherever in the turn the pointer is.
	@State private var hoveredTurn: UUID?

	private var chat: AIChatModel { store.chat }
	private var isOpen: Bool { store.chatOpen }

	/// For each message: the last message of its turn (a user message is a turn of its own; an answer
	/// is every assistant message up to the next user one), and for that last one, the whole answer's
	/// text, which Copy takes.
	private func turns() -> (end: [UUID], answerText: [UUID: String]) {
		let list = chat.messages
		var end = list.map(\.id)
		for i in stride(from: list.count - 2, through: 0, by: -1) where list[i].role == .assistant && list[i + 1].role == .assistant {
			end[i] = end[i + 1]
		}
		var text: [UUID: String] = [:]
		for (i, message) in list.enumerated() where message.role == .assistant && end[i] == message.id {
			var parts: [String] = []
			var j = i
			while j >= 0, list[j].role == .assistant { if !list[j].text.isEmpty { parts.insert(list[j].text, at: 0) }; j -= 1 }
			text[message.id] = parts.joined(separator: "\n\n")
		}
		return (end, text)
	}

	var body: some View {
		VStack(spacing: 0) {
			header
				.zIndex(10)
			Rectangle().fill(AppTheme.cardStroke).frame(height: 1)
			// The message box floats over the bottom of the conversation, which fades out behind it.
			conversation
				.safeAreaInset(edge: .bottom, spacing: 0) { composer }
		}
		.frame(width: panelWidth)
		.background(AppTheme.background)
		.clipShape(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous).stroke(AppTheme.outline, lineWidth: 1))
		.dropDestination(for: URL.self) { urls, _ in
			attach(urls.filter(\.isFileURL))
			return true
		} isTargeted: { dropTargeted = $0 }
		.overlay {
			if dropTargeted {
				RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous)
					.fill(Color.accentColor.opacity(0.08))
					.overlay(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous)
						.strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
					.overlay(Text("Drop files to attach").font(Typography.bodySemibold).foregroundStyle(Color.accentColor))
					.allowsHitTesting(false)
			}
		}
		.onAppear { if isOpen { focused = true } }
		.task(id: store.currentAccountID) { chat.loadHistory(accountID: store.currentAccountID) }
		.onChange(of: isOpen) { _, open in if open { focused = true } else { modelOpen = false } }
		.onChange(of: modelOpen) { _, _ in modelQuery = ""; modelProvider = nil }
	}

	// MARK: Header

	private var header: some View {
		HStack(spacing: 8) {
			if chat.messages.isEmpty {
				HIcon(.sparkles, size: 15).foregroundStyle(.secondary)
				Text("Assistant").font(.system(size: 15, weight: .semibold))
			} else {
				// In a conversation, the title is the way back to the start screen.
				Button { chat.reset(); focused = true } label: {
					HStack(spacing: 8) {
						HIcon(.arrowLeft, size: 15).foregroundStyle(.secondary)
						Text("Assistant").font(.system(size: 15, weight: .semibold))
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help("Back to the assistant home")
			}
			Spacer(minLength: 8)
			modelMenu
			TitlebarIconButton(icon: store.chatExpanded ? .shrink : .expand, help: store.chatExpanded ? "Minimize" : "Maximize",
							   tooltipAbove: false, iconSize: 15) {
				withAnimation(.easeInOut(duration: 0.28)) { store.chatExpanded.toggle() }
			}
		}
		.padding(.horizontal, 16)
		.frame(height: PaneHeader.height)
	}

	/// The model in use, and a dropdown of every model of every configured provider.
	private var modelMenu: some View {
		Button { withAnimation(.snappy(duration: 0.2)) { modelOpen.toggle() } } label: {
			HStack(spacing: 5) {
				Text(store.ai.active?.model ?? "Model").font(Typography.meta.weight(.medium)).lineLimit(1).truncationMode(.middle)
				HIcon(.chevronDown, size: 11).rotationEffect(.degrees(modelOpen ? 180 : 0))
			}
			.foregroundStyle(modelOpen ? Color.primary : Color.secondary)
			.padding(.horizontal, 8).padding(.vertical, 5)
			.frame(maxWidth: 150)
			.background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(modelOpen ? AppTheme.rowHighlight : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.overlay(alignment: .topTrailing) {
			if modelOpen { modelDropdown.offset(y: 32) }
		}
		.clickAway(isActive: modelOpen) { withAnimation(.snappy(duration: 0.2)) { modelOpen = false } }
	}

	private func chooseModel(_ provider: AIProviderConfig, _ model: String) {
		store.ai.select(providerID: provider.id, model: model)
		withAnimation(.snappy(duration: 0.2)) { modelOpen = false }
	}

	private var modelDropdown: some View {
		// Everything the rows need is worked out once here, not per row.
		let q = modelQuery.trimmingCharacters(in: .whitespaces).lowercased()
		let activeKey = store.ai.active.map { "\($0.id)|\($0.model)" }
		let providers = store.ai.readyProviders
		// Several providers: pick one first, then its models. Searching looks through all of them.
		let drillProvider = providers.count > 1 ? providers.first { $0.id == modelProvider } : providers.first
		let showProviders = providers.count > 1 && drillProvider == nil && q.isEmpty
		let groups = providers
			.filter { q.isEmpty ? $0.id == drillProvider?.id : true }
			.map { (provider: $0, models: q.isEmpty ? $0.choices : $0.choices.filter { $0.lowercased().contains(q) }) }
			.filter { !$0.models.isEmpty }
		return DropdownCard(width: 260, anchor: .topTrailing) {
			if !showProviders {
				if providers.count > 1, q.isEmpty, let drillProvider {
					DropdownRow(label: drillProvider.name, icon: .arrowLeft) { withAnimation(.snappy(duration: 0.2)) { modelProvider = nil } }
					DropdownDivider()
				}
				DropdownSearchField(text: $modelQuery) {
					if let first = groups.first, let model = first.models.first { chooseModel(first.provider, model) }
				}
			}
			if showProviders {
				ForEach(providers) { provider in
					DropdownRow(label: provider.name, isSelected: provider.id == store.ai.active?.id, trailing: .chevronRight) {
						withAnimation(.snappy(duration: 0.2)) { modelProvider = provider.id }
					}
				}
			} else {
				// Lazy, like every long dropdown: only the rows near the viewport are built.
				DropdownScroll(target: q.isEmpty ? activeKey : nil) {
					if groups.isEmpty { DropdownNoResults() }
					ForEach(groups, id: \.provider.id) { group in
						if !q.isEmpty && providers.count > 1 { DropdownLabel(title: group.provider.name) }
						ForEach(group.models, id: \.self) { model in
							let key = "\(group.provider.id)|\(model)"
							DropdownRow(label: model, isSelected: key == activeKey) { chooseModel(group.provider, model) }
								.id(key)
						}
					}
				}
			}
			DropdownDivider()
			DropdownRow(label: "Manage Providers…", icon: .settings) {
				withAnimation(.snappy(duration: 0.2)) { modelOpen = false }
				store.settingsPage = .ai
			}
		}
	}

	// MARK: Conversation

	private var conversation: some View {
		ScrollViewReader { proxy in
			ScrollView {
				// No spacing of its own: each row sets the gap above it, so steps of one answer sit closer
				// together than a new turn does, and never by accident of what a row holds.
				LazyVStack(alignment: .leading, spacing: 0) {
					if chat.messages.isEmpty { welcome }
					let turn = turns()
					let pieces = ChatLayout.pieces(for: chat.messages)
					ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
						ChatMessageRow(
							message: message,
							gap: rowGap(index, pieces),
							pieces: pieces[index],
							turnID: turn.end[index],
							answerText: turn.answerText[message.id],
							hoveredTurn: $hoveredTurn
						).id(message.id)
					}
					// While a request is unfinished there is always a running task or "Thinking…" in view.
					if chat.busy, chat.messages.last?.tools.contains(where: { $0.status == .running }) != true {
						HStack(spacing: 6) {
							ProgressView().controlSize(.mini).frame(width: 12, height: 12)
							Text("Thinking…").font(Typography.body).foregroundStyle(.secondary).lineSpacing(Typography.chatLineSpacing)
						}
						.padding(.top, 8)
					}
					Color.clear.frame(height: 1).id("bottom")
				}
				.padding(16)
				.frame(maxWidth: Self.readableWidth, alignment: .leading)
				.frame(maxWidth: .infinity)
			}
			.onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("bottom") }
			.onChange(of: chat.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom") } }
		}
	}

	/// The space above a message: 14 after the user's, else the same rule as inside a message, measured
	/// from the last thing shown before it to the first thing it shows.
	private func rowGap(_ index: Int, _ pieces: [[Piece]]) -> CGFloat {
		guard index > 0 else { return 0 }
		let message = chat.messages[index]
		if message.role == .user { return 14 }
		guard let first = pieces[index].first else { return 0 }
		guard chat.messages[index - 1].role == .assistant,
			  let last = pieces[..<index].last(where: { !$0.isEmpty })?.last else { return 14 }
		return ChatLayout.gap(last, first)
	}

	private struct Prompt: Identifiable {
		let label: String, detail: String, prompt: String, icon: AppIcon
		/// What a tap does instead of sending `prompt`.
		var action: (() -> Void)?
		var id: String { label }
	}

	/// The MCP example: a prompt about the first connected server, or, with none, a way to add one.
	private var mcpPrompt: Prompt {
		if let server = store.mcp.servers.first {
			return Prompt(label: "Use \(server.name)", detail: "Look something up there, then act on it",
						  prompt: "Use the \(server.name) MCP server: list its tools and tell me what you can look up or do with them. Don't change anything yet.", icon: .link)
		}
		return Prompt(label: "Connect an MCP server", detail: "Let me look things up in your other services", prompt: "", icon: .link) {
			store.settingsPage = .mcp
		}
	}

	/// Starters like the web assistant's: about the open email when there is one, else the mailbox.
	private var prompts: [Prompt] {
		let mcp = mcpPrompt
		if store.openEmailIDForAI != nil {
			return [
				Prompt(label: "Summarize this", detail: "Key points of the open thread", prompt: "Read this thread and summarize its key points.", icon: .summarize),
				Prompt(label: "Draft a reply", detail: "Write a reply for you to review", prompt: "Read this thread and draft a reply.", icon: .reply),
				Prompt(label: "List action items", detail: "What needs doing", prompt: "Read this thread and list the action items.", icon: .check),
				mcp,
			]
		}
		return [
			Prompt(label: "Summarize recent mail", detail: "What came in lately", prompt: "Summarize my recent email in this mailbox.", icon: .summarize),
			Prompt(label: "Reply to my latest email", detail: "Draft it for you to review", prompt: "Read my latest email and draft a reply.", icon: .reply),
			Prompt(label: "Find action items", detail: "Across recent mail", prompt: "Find action items in my recent email.", icon: .check),
			mcp,
		]
	}

	/// Rises and fades in when the panel opens, and back out when it closes; each block a beat later.
	private func entrance(_ step: Int) -> some ViewModifier {
		Entrance(isOpen: isOpen, step: step)
	}

	private var welcome: some View {
		VStack(alignment: .leading, spacing: 18) {
			VStack(alignment: .leading, spacing: 8) {
				Text("How can I help?").font(.system(size: 17, weight: .semibold))
				ForEach(Array(prompts.enumerated()), id: \.element.id) { index, item in
					Button { if let action = item.action { action() } else { send(item.prompt) } } label: {
						HStack(spacing: 10) {
							HIcon(item.icon, size: 16).foregroundStyle(.secondary).frame(width: 20)
							VStack(alignment: .leading, spacing: 1) {
								Text(item.label).font(Typography.bodySemibold)
								Text(item.detail).font(Typography.meta).foregroundStyle(.secondary)
							}
							Spacer(minLength: 0)
						}
						.padding(.horizontal, 12).padding(.vertical, 9)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.modifier(entrance(index))
				}
			}
			if !chat.history.isEmpty {
				VStack(alignment: .leading, spacing: 2) {
					Text("Recent conversations").font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
						.padding(.bottom, 4)
					ForEach(Array(chat.history.prefix(6).enumerated()), id: \.element.id) { index, saved in
						HistoryRow(chat: saved) { chat.open(saved) } onDelete: { chat.delete(saved) }
							.modifier(entrance(prompts.count + index))
					}
				}
			}
		}
		.padding(.bottom, 4)
	}

	// MARK: Input

	private var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

	private var composer: some View {
		VStack(alignment: .leading, spacing: 4) {
			if !attachments.isEmpty {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 6) {
						ForEach(attachments) { file in
							AttachmentChip(name: file.name, kind: file.kind) { remove(file) }
						}
					}
					.padding(.top, 10).padding(.leading, 12)
				}
			}
			if let attachError {
				Text(attachError).font(Typography.meta).foregroundStyle(.orange).padding(.top, 8).padding(.leading, 12)
			}
			HStack(alignment: .bottom, spacing: 8) {
				Button(action: chooseFiles) {
					HIcon(.add, size: 22)
						.foregroundStyle(.secondary)
						.frame(width: 42, height: 42)
						.background(Circle().fill(AppTheme.outline.opacity(0.5)))
				}
				.buttonStyle(.plain)
				.padding(.bottom, 1).padding(.leading, 4)
				.help("Attach a file")
				MarkdownInput(text: $input, height: $inputHeight, focusRequest: focusRequest) { send(input) }
					.frame(height: inputHeight)
					.overlay(alignment: .topLeading) {
						if input.isEmpty {
							Text("Message the assistant").font(Typography.body).foregroundStyle(.tertiary).allowsHitTesting(false)
						}
					}
					.frame(minHeight: 28, alignment: .center)
					.padding(.vertical, 8)
				Button {
					if chat.busy { chat.stop() } else { send(input) }
				} label: {
					HIcon(chat.busy ? .cancel : .send, size: 15)
						.foregroundStyle(AppTheme.prominentPillText)
						.frame(width: 28, height: 28)
						.background(Circle().fill(AppTheme.prominentPillFill))
				}
				.buttonStyle(.plain)
				.disabled(!chat.busy && !canSend)
				.opacity(!chat.busy && !canSend ? 0.4 : 1)
				.padding(.bottom, 8)
				.help(chat.busy ? "Stop" : "Send")
			}
		}
		.padding(.trailing, 12)
		.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 28)
		.frame(maxWidth: Self.readableWidth)
		.frame(maxWidth: .infinity)
		.background(
			LinearGradient(stops: [.init(color: AppTheme.background.opacity(0), location: 0),
								   .init(color: AppTheme.background.opacity(0.85), location: 0.55),
								   .init(color: AppTheme.background, location: 1)],
						   startPoint: .top, endPoint: .bottom)
		)
	}

	private func chooseFiles() {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		panel.message = "Choose files for the assistant to read: CSV, text, PDF, Word or images."
		guard panel.runModal() == .OK else { return }
		attach(panel.urls)
	}

	private func attach(_ urls: [URL]) {
		attachError = nil
		for url in urls {
			do { attachments.append(try ChatFiles.ingest(url)) } catch { attachError = error.localizedDescription }
		}
	}

	private func remove(_ file: ChatAttachment) {
		attachments.removeAll { $0.id == file.id }
		// Only a file not yet sent is deleted: a sent one is still read by later turns.
		if !chat.attachments.contains(where: { $0.id == file.id }) { ChatFiles.remove(file) }
	}

	private func send(_ text: String) {
		guard !chat.busy, canSend else { return }
		chat.send(MarkdownInput.markdown(from: text), attachments: attachments, store: store)
		input = ""
		attachments = []
		attachError = nil
	}
}

/// Slides up and fades in when the panel opens (after the panel itself starts moving) and slides
/// down and fades out when it closes.
private struct Entrance: ViewModifier {
	var isOpen: Bool
	var step: Int
	/// A panel mounted already open (when it floats) still plays the entrance.
	@State private var appeared = false

	func body(content: Content) -> some View {
		let visible = isOpen && appeared
		content
			.opacity(visible ? 1 : 0)
			.offset(y: visible ? 0 : 24)
			.animation(visible ? .easeOut(duration: 0.35).delay(0.1 + 0.05 * Double(step)) : .easeIn(duration: 0.16), value: visible)
			.onAppear { appeared = true }
	}
}

private struct HistoryRow: View {
	var chat: SavedChat
	var open: () -> Void
	var onDelete: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: open) {
			HStack(spacing: 8) {
				VStack(alignment: .leading, spacing: 1) {
					Text(chat.title).font(Typography.body).lineLimit(1)
					Text(Self.formatter.localizedString(for: chat.updated, relativeTo: Date()))
						.font(Typography.meta).foregroundStyle(.secondary)
				}
				Spacer(minLength: 4)
				if isHovering {
					Button(action: onDelete) { HIcon(.trash, size: 13).foregroundStyle(.secondary) }
						.buttonStyle(.plain).help("Delete")
				}
			}
			.padding(.horizontal, 10).padding(.vertical, 6)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isHovering ? AppTheme.rowHighlight : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
	}

	private static let formatter: RelativeDateTimeFormatter = {
		let f = RelativeDateTimeFormatter()
		f.unitsStyle = .short
		return f
	}()
}

/// What an assistant message shows, top to bottom.
fileprivate enum Piece {
	case run(ChatToolRun)
	case group([ChatToolRun])
	case card(ChatToolRun)
	case block(ChatBlock)
	case offer(MCPOffer)

	var isText: Bool {
		switch self {
		case .block(.prose), .block(.heading): true
		default: false
		}
	}
	var isStep: Bool {
		switch self {
		case .run, .group: true
		default: false
		}
	}
}

fileprivate enum ChatLayout {
	/// A step that is done and needs nothing from the user; several in a row fold into one line.
	static func isPlain(_ run: ChatToolRun) -> Bool {
		(run.approval == nil || run.approval?.decision != nil) && run.draftID == nil && run.status != .waiting && run.status != .failed
	}

	/// Lines of text sit close together; text next to anything else gets 1.5 lines of air.
	static func gap(_ above: Piece, _ below: Piece) -> CGFloat {
		if above.isText && below.isText { return 4 }
		if above.isStep && below.isStep { return 6 }
		return Typography.chatBlockGap
	}

	/// The pieces of every message. Steps that follow one another, even across messages with no text
	/// between them, become one group shown where the first of them is; later messages skip those lines.
	static func pieces(for messages: [ChatMessage]) -> [[Piece]] {
		var groups: [Int: [ChatToolRun]] = [:]
		var hidden = Set<Int>()
		var i = 0
		while i < messages.count {
			guard messages[i].role == .assistant, messages[i].tools.contains(where: isPlain) else { i += 1; continue }
			var j = i
			var runs = messages[i].tools.filter(isPlain)
			var followers: [Int] = []
			while messages[j].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, j + 1 < messages.count,
				  messages[j + 1].role == .assistant, messages[j + 1].tools.contains(where: isPlain) {
				j += 1
				runs += messages[j].tools.filter(isPlain)
				followers.append(j)
			}
			if runs.count > 1 { groups[i] = runs; hidden.formUnion(followers) }
			i = j + 1
		}
		return messages.indices.map { index in
			let message = messages[index]
			guard message.role == .assistant else { return [] }
			var out: [Piece] = []
			var cards: [Piece] = []
			if let runs = groups[index] { out.append(.group(runs)) }
			for run in message.tools {
				let folded = isPlain(run) && (groups[index] != nil || hidden.contains(index))
				if !folded { out.append(.run(run)) }
				if run.batch != nil { cards.append(.card(run)) }
			}
			return out + cards + ChatMarkdown.blocks(from: message.text).map { .block($0) } + (message.mcpOffers ?? []).map { .offer($0) }
		}
	}
}

/// One message: the user's in a bubble on the right, the assistant's as plain text on the left with
/// its tool activity above. Pointing at either shows when it was written and what can be done with it.
private struct ChatMessageRow: View {
	@Environment(MailStore.self) private var store
	var message: ChatMessage
	/// The space above this row, set by the list.
	var gap: CGFloat = 0
	fileprivate var pieces: [Piece] = []
	/// The last message of this message's turn. Only that one carries the time and the buttons, so the
	/// steps in the middle of an answer (notes between tool calls) have none and reserve no room.
	var turnID: UUID
	/// For the last message of an answer: everything the assistant wrote in it, which Copy takes.
	var answerText: String?
	@Binding var hoveredTurn: UUID?
	private var endsTurn: Bool { turnID == message.id }
	/// Pointing anywhere in the turn shows its buttons.
	private var isHovering: Bool { hoveredTurn == turnID }
	private func hover(_ inside: Bool) {
		if inside { hoveredTurn = turnID } else if hoveredTurn == turnID { hoveredTurn = nil }
	}
	@State private var isEditing = false
	@State private var draft = ""
	@FocusState private var editorFocused: Bool

	/// Any message that reached the model. One that had credentials in it is shown with them hidden;
	/// edited, it is sent with that placeholder, and the credentials are typed in again if they are
	/// needed (they are saved when the message is sent).
	private var canEdit: Bool { message.wireStart != nil }

	private func startEditing() {
		draft = message.text
		isEditing = true
		editorFocused = true
	}

	private func update() {
		let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		isEditing = false
		// Unchanged text is only a cancel: the answer below it stays.
		if !text.isEmpty, text != message.text { store.chat.edit(message.id, to: text, store: store) }
	}

	/// The message as a box the user can type in, with the two ways out.
	private var editor: some View {
		VStack(alignment: .trailing, spacing: 8) {
			TextEditor(text: $draft)
				.font(Typography.body).lineSpacing(Typography.chatLineSpacing)
				.scrollContentBackground(.hidden)
				.focused($editorFocused)
				.frame(minHeight: 64, maxHeight: 220)
				.fixedSize(horizontal: false, vertical: true)
				.padding(8)
				.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
				.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
				.onExitCommand { isEditing = false }
			HStack(spacing: 6) {
				Button("Cancel") { isEditing = false }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
				Button("Update", action: update).buttonStyle(.pillProminent)
					.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			}
		}
	}

	/// Still being written: nothing to copy or redo yet.
	private var isStreaming: Bool { store.chat.busy && store.chat.messages.last?.id == message.id }

	var body: some View {
		switch message.role {
		case .user:
			VStack(alignment: .trailing, spacing: 2) {
				if isEditing {
					editor
				} else {
					ForEach(message.attachments ?? []) { file in AttachmentChip(name: file.name, kind: file.kind, onRemove: nil) }
					VStack(alignment: .leading, spacing: 4) {
						ForEach(Array(ChatMarkdown.blocks(from: message.text).enumerated()), id: \.offset) { _, block in blockView(block) }
					}
						.padding(.horizontal, 12).padding(.vertical, 8)
						.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
					MessageActions(message: message, visible: isHovering && !isStreaming, alignment: .trailing, canEdit: canEdit, onEdit: startEditing)
				}
			}
			.frame(maxWidth: .infinity, alignment: .trailing)
			.padding(.leading, 40)
			.padding(.top, gap)
			.contentShape(Rectangle())
			.onHover(perform: hover)
		case .assistant:
			VStack(alignment: .leading, spacing: 0) {
				ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
					pieceView(piece)
						.padding(.top, index == 0 ? 0 : ChatLayout.gap(pieces[index - 1], piece))
				}
				if !message.text.isEmpty && endsTurn {
					MessageActions(message: message, visible: isHovering && !isStreaming, alignment: .leading, copyText: answerText)
						.padding(.top, 8)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.top, pieces.isEmpty ? 0 : gap)
			.contentShape(Rectangle())
			.onHover(perform: hover)
		}
	}

	@ViewBuilder
	private func pieceView(_ piece: Piece) -> some View {
		switch piece {
		case .run(let run): ToolRow(run: run)
		case .group(let runs): ToolGroup(runs: runs)
		case .card(let run): EmailBatchCard(runID: run.id)
		case .offer(let offer): MCPOfferCard(offer: offer)
		case .block(let block): blockView(block)
		}
	}

	@ViewBuilder
	private func blockView(_ block: ChatBlock) -> some View {
		switch block {
		case .prose(let text):
			proseView(text)
		case .heading(let level, let text):
			Text(Self.markdown(text, preservingWhitespace: false))
				.font(.system(size: level <= 1 ? 16 : (level == 2 ? 15 : 14), weight: .semibold))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.top, 2)
		case .code(let code):
			ScrollView(.horizontal, showsIndicators: false) {
				Text(code).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
					.padding(10)
			}
			.background(AppTheme.composerContextFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
		case .quote(let text):
			QuoteBlock(text: text)
		case .table(let table):
			ChatTableView(table: table)
		}
	}

	/// Prose with its bullet items set as rows: a larger bullet, then the text, which wraps under itself.
	private func proseView(_ text: String) -> some View {
		var segments: [(bullet: Bool, indent: Int, text: String)] = []
		for line in text.components(separatedBy: "\n") {
			let indent = line.prefix { $0 == " " }.count
			let rest = line.dropFirst(indent)
			if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("• ") {
				segments.append((true, indent, String(rest.dropFirst(2))))
			} else if let last = segments.last, !last.bullet {
				segments[segments.count - 1].text += "\n" + line
			} else {
				segments.append((false, 0, line))
			}
		}
		let color: Color = message.isError ? .orange : .primary
		return VStack(alignment: .leading, spacing: 2) {
			ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
				if segment.bullet {
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Text("•").font(.system(size: Typography.baseSize * 1.5)).foregroundStyle(color)
							.padding(.vertical, -4)
						Text(Self.markdown(segment.text))
							.font(Typography.body).lineSpacing(Typography.chatLineSpacing).foregroundStyle(color)
							.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
					}
					.padding(.leading, CGFloat(segment.indent) * 6)
				} else {
					Text(Self.markdown(segment.text))
						.font(Typography.body).lineSpacing(Typography.chatLineSpacing).foregroundStyle(color)
						.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
				}
			}
		}
	}

	static func markdown(_ text: String, preservingWhitespace: Bool = true) -> AttributedString {
		let syntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax = preservingWhitespace ? .inlineOnlyPreservingWhitespace : .inlineOnly
		return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: syntax))) ?? AttributedString(text)
	}
}

/// A markdown table: a header row and body rows in a grid with hairlines, columns aligned as the
/// separator row asks. A table wider than the column scrolls sideways instead of squeezing its text.
private struct ChatTableView: View {
	var table: ChatTable

	private func alignment(_ column: Int) -> Alignment {
		switch table.alignments.indices.contains(column) ? table.alignments[column] : .leading {
		case .leading: .leading
		case .center: .center
		case .trailing: .trailing
		}
	}

	private func cell(_ text: String, column: Int, isHeader: Bool, maxCell: CGFloat?) -> some View {
		Text(ChatMessageRow.markdown(text, preservingWhitespace: false))
			.font(isHeader ? Typography.notice.weight(.semibold) : Typography.notice)
			.textSelection(.enabled)
			.multilineTextAlignment(table.alignments.indices.contains(column) && table.alignments[column] == .trailing ? .trailing : (table.alignments.indices.contains(column) && table.alignments[column] == .center ? .center : .leading))
			.fixedSize(horizontal: false, vertical: true)
			.frame(minWidth: 56, maxWidth: maxCell ?? .infinity, alignment: alignment(column))
			.padding(.horizontal, 8).padding(.vertical, 6)
	}

	/// The grid with every cell at most `maxCell` wide (its own width when nil).
	private func grid(maxCell: CGFloat?) -> some View {
		Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
			GridRow {
				ForEach(Array(table.header.enumerated()), id: \.offset) { column, text in
					cell(text, column: column, isHeader: true, maxCell: maxCell)
				}
			}
			ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
				Divider().gridCellUnsizedAxes(.horizontal).overlay(AppTheme.cardStroke)
				GridRow {
					ForEach(Array(row.enumerated()), id: \.offset) { column, text in
						cell(text, column: column, isHeader: false, maxCell: maxCell)
					}
				}
			}
		}
		.frame(maxWidth: maxCell == nil ? .infinity : nil, alignment: .leading)
	}

	/// The full width of the column when that fits; else with long cells wrapped; else, for a
	/// table with too many columns for that, scrolling sideways.
	var body: some View {
		ViewThatFits(in: .horizontal) {
			grid(maxCell: nil)
			grid(maxCell: 150)
			grid(maxCell: 120)
			grid(maxCell: 96)
			ScrollView(.horizontal) { grid(maxCell: 240).padding(.bottom, 4) }
		}
		.background(AppTheme.composerContextFill.opacity(0.35))
		.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
	}
}

/// When a message was written, and the buttons under it: copy, and for the user's own, answer again
/// from it. The row keeps its place when hidden, so the chat does not shift as the pointer moves.
private struct MessageActions: View {
	@Environment(MailStore.self) private var store
	var message: ChatMessage
	var visible: Bool
	var alignment: HorizontalAlignment
	/// For a user message: whether it can be edited, and what opens it for editing in place.
	var canEdit = false
	var onEdit: (() -> Void)?
	/// What Copy takes, when not just this message's own text.
	var copyText: String?
	@State private var copied = false

	private var canRegenerate: Bool { message.role == .user && message.wireStart != nil && !store.chat.busy }

	var body: some View {
		HStack(spacing: 2) {
			if alignment == .trailing { Spacer(minLength: 0) }
			if let date = message.date {
				Text(ChatTime.label(date)).font(Typography.meta).foregroundStyle(.secondary)
					.help(ChatTime.full(date))
					.padding(.trailing, 4)
			}
			TitlebarIconButton(icon: copied ? .check : .copy, help: copied ? "Copied" : "Copy", tooltipAbove: true, iconSize: 14) {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(copyText ?? message.text, forType: .string)
				copied = true
				Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
			}
			// Always beside Copy for the user's own messages; dimmed when this one cannot be edited.
			if message.role == .user, let onEdit {
				TitlebarIconButton(icon: .edit, help: canEdit ? "Edit message" : "This message can't be edited",
								   isEnabled: !store.chat.busy, isDimmed: !canEdit, tooltipAbove: true, iconSize: 14) {
					if canEdit { onEdit() }
				}
			}
			if message.role == .user {
				TitlebarIconButton(icon: .refresh, help: "Regenerate the response from this message", isEnabled: canRegenerate, tooltipAbove: true, iconSize: 14) {
					store.chat.regenerate(from: message.id, store: store)
				}
			}
			if alignment == .leading { Spacer(minLength: 0) }
		}
		.frame(height: TitlebarIconButton.size)
		.opacity(visible ? 1 : 0)
		.allowsHitTesting(visible)
		.animation(.easeOut(duration: 0.12), value: visible)
	}
}

/// "5 minutes ago" for a message from the last day, the full date after that.
enum ChatTime {
	static func label(_ date: Date, now: Date = Date()) -> String {
		let seconds = max(0, Int(now.timeIntervalSince(date)))
		if seconds < 60 { return "Just now" }
		if seconds < 3_600 { let n = seconds / 60; return "\(n) minute\(n == 1 ? "" : "s") ago" }
		if seconds < 86_400 { let n = seconds / 3_600; return "\(n) hour\(n == 1 ? "" : "s") ago" }
		return full(date)
	}

	/// "03:45 PM Nov, 14 2026"
	static func full(_ date: Date) -> String { formatter.string(from: date) }

	private static let formatter: DateFormatter = {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "hh:mm a MMM, dd yyyy"
		return f
	}()
}

/// Several finished steps as one line ("Ran an MCP tool, listed templates, prepared emails and 2 more…");
/// clicking it shows or hides each step.
/// An MCP server added in the chat, with the button that saves it to MCP credentials.
private struct MCPOfferCard: View {
	@Environment(MailStore.self) private var store
	var offer: MCPOffer
	@State private var problem: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 10) {
				HIcon(.link, size: 15).foregroundStyle(.secondary)
				VStack(alignment: .leading, spacing: 0) {
					Text(offer.name).font(Typography.bodySemibold)
					Text(offer.host).font(Typography.meta).foregroundStyle(.secondary)
				}
				Spacer(minLength: 8)
				if store.mcp.isSaved(offer.serverID) {
					HStack(spacing: 4) { HIcon(.check, size: 12); Text("Saved to MCP credentials") }
						.font(Typography.meta).foregroundStyle(.secondary)
				} else if store.mcp.isPending(offer.serverID) {
					Button("Save") { problem = store.mcp.promote(offer.serverID) }
						.buttonStyle(.pill).help("Save to MCP credentials")
					Button("Always save MCP credentials") {
						store.mcp.alwaysSave = true
						problem = store.mcp.promote(offer.serverID)
					}
					.buttonStyle(.pill).help("Save new MCP servers without asking. Turn it off in Settings → MCP Credentials.")
				} else {
					Text("Paste it again to save").font(Typography.meta).foregroundStyle(.secondary)
				}
			}
			if let problem { Text(problem).font(Typography.meta).foregroundStyle(.orange) }
		}
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(AppTheme.composerContextFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
	}
}

/// A file attached to the message box or to a sent message.
private struct AttachmentChip: View {
	var name: String
	var kind: ChatAttachment.Kind
	var onRemove: (() -> Void)?

	var body: some View {
		HStack(spacing: 5) {
			HIcon(.attachment, size: 12).foregroundStyle(.secondary)
			Text(name).font(Typography.meta).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180)
			if let onRemove {
				Button(action: onRemove) { HIcon(.close, size: 10).foregroundStyle(.secondary) }
					.buttonStyle(.plain).help("Remove")
			}
		}
		.padding(.horizontal, 8).padding(.vertical, 4)
		.background(AppTheme.elevated, in: Capsule())
		.overlay(Capsule().stroke(AppTheme.outline, lineWidth: 1))
	}
}

private struct ToolGroup: View {
	var runs: [ChatToolRun]
	@State private var expanded = false

	private var summary: String {
		var seen = Set<String>()
		let labels = runs.compactMap { run -> String? in
			let label = AIMailTools.activity(run.name, done: true)
			return seen.insert(label).inserted ? label : nil
		}
		let shown = labels.prefix(3).enumerated().map { $0.offset == 0 ? $0.element : Self.lowered($0.element) }
		var text = shown.joined(separator: ", ")
		if labels.count > 3 { text += " and \(labels.count - 3) more" }
		return text + "…"
	}

	private static func lowered(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Button { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } } label: {
				HStack(spacing: 6) {
					HIcon(.chevronRight, size: 14).foregroundStyle(.secondary)
						.frame(width: 14, height: 14)
						.rotationEffect(.degrees(expanded ? 90 : 0))
					Text(summary).font(Typography.body).foregroundStyle(.secondary).lineLimit(1)
					if runs.contains(where: { $0.status == .running }) {
						ProgressView().controlSize(.mini).frame(width: 12, height: 12)
					}
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.help(expanded ? "Hide steps" : "Show steps")
			if expanded {
				VStack(alignment: .leading, spacing: 6) {
					ForEach(runs) { ToolRow(run: $0) }
				}
			}
		}
	}
}

private struct ToolRow: View {
	@Environment(MailStore.self) private var store
	var run: ChatToolRun

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			line
			if run.status == .waiting, let approval = run.approval, approval.decision == nil { ApprovalCard(callID: run.id, approval: approval) }
		}
	}

	private var line: some View {
		HStack(spacing: 8) {
			status
			if run.status == .done, let id = run.draftID {
				Button {
					if let saved = run.draft { store.openChatDraft(saved) } else { store.editDraft(id, title: run.name == "draft_reply" ? "Reply" : "New Message") }
				} label: {
					Text((run.draft?.isReply ?? (run.name == "draft_reply")) ? "Open reply" : "Open email")
						.font(Typography.meta.weight(.medium))
						.padding(.horizontal, 8).padding(.vertical, 2)
						.background(AppTheme.elevated, in: Capsule())
						.overlay(Capsule().stroke(AppTheme.outline, lineWidth: 1))
						.contentShape(Capsule())
				}
				.buttonStyle(.plain)
				.help("Open this draft in the composer")
			}
		}
	}

	private var label: String {
		let base = run.status == .failed ? "\(AIMailTools.activity(run.name, done: true)) failed" : AIMailTools.activity(run.name, done: run.status == .done)
		if run.status == .waiting { return "Waiting for you" + (run.detail.map { " — \($0)" } ?? "") }
		return base + (run.detail.map { " — \($0)" } ?? "")
	}

	private var status: some View {
		HStack(spacing: 6) {
			switch run.status {
			case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
			case .waiting: HIcon(.clock, size: 12).foregroundStyle(.orange).frame(width: 12, height: 12)
			case .done: HIcon(.check, size: 12).foregroundStyle(.secondary).frame(width: 12, height: 12)
			case .failed: HIcon(.close, size: 12).foregroundStyle(.orange).frame(width: 12, height: 12)
			}
			Text(label)
				.font(Typography.body).foregroundStyle(.secondary).lineSpacing(Typography.chatLineSpacing)
		}
	}
}

/// Asks before an MCP tool that may change something runs: what it is and the arguments it was
/// given. "Always allow" remembers the tool for that server.
private struct ApprovalCard: View {
	@Environment(MailStore.self) private var store
	var callID: String
	var approval: ToolApproval

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Allow \(approval.server) to run \(approval.tool)?").font(Typography.bodySemibold)
			ScrollView {
				Text(approval.arguments).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxHeight: 110)
			.padding(8)
			.background(AppTheme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
			HStack(spacing: 6) {
				Button("Allow") { store.chat.decide(callID, .allowed) }.buttonStyle(.pillProminent)
				Button("Always allow") { store.chat.decide(callID, .always) }.buttonStyle(.pill)
				Button("Deny") { store.chat.decide(callID, .denied) }.buttonStyle(.pill)
			}
		}
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(AppTheme.composerContextFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.5), lineWidth: 1))
	}
}

/// Wording the assistant offers, set apart from its own prose, with a button to copy it.
private struct QuoteBlock: View {
	var text: String
	@State private var copied = false

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Text(text)
				.font(Typography.notice)
				.lineSpacing(max(0, Typography.chatLineSpacing - 1))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)
			Button {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(text, forType: .string)
				copied = true
				Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
			} label: {
				HIcon(copied ? .check : .copy, size: 13)
					.foregroundStyle(.secondary)
					.frame(width: 22, height: 22)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.help(copied ? "Copied" : "Copy")
		}
		.padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 10)
		.background(AppTheme.composerContextFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
	}
}
