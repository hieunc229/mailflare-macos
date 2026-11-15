import SwiftUI
import MailflareCore
import UniformTypeIdentifiers

struct ComposeView: View {
	@Environment(MailStore.self) private var store
	@State var draft: ComposeDraft
	@State private var error: String?
	@State private var controller = ComposerController()
	@Environment(\.colorScheme) private var colorScheme
	@State private var showQuoted = false
	@State private var quotedHeight: CGFloat = 0
	@State private var saveTemplateOpen = false
	@State private var templateTitle = ""
	@State private var isDropTarget = false
	@State private var sendMenuOpen = false
	@State private var fromOpen = false
	@State private var showCc: Bool
	/// Fixed when the composer opens: tall, but always shorter than the window it sits in.
	@State private var height: CGFloat = ComposeView.fittingHeight()
	@State private var showBcc: Bool
	@State private var promptOpen = false
	@State private var prompt = ""
	@State private var writing = false
	@State private var writeTask: Task<Void, Never>?
	@FocusState private var promptFocused: Bool

	/// The draft as the composer opened (a reply arrives with recipients and a subject filled in).
	private let initial: ComposeDraft

	/// Whether the user has typed, attached or changed anything since it opened.
	private var hasChanges: Bool {
		func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
		return clean(draft.to) != clean(initial.to) || clean(draft.cc) != clean(initial.cc) || clean(draft.bcc) != clean(initial.bcc)
			|| clean(draft.subject) != clean(initial.subject) || clean(draft.body) != clean(initial.body)
			|| draft.attachments.map(\.id) != initial.attachments.map(\.id)
	}

	init(draft: ComposeDraft) {
		initial = draft
		_draft = State(initialValue: draft)
		_showCc = State(initialValue: !draft.cc.isEmpty)
		_showBcc = State(initialValue: !draft.bcc.isEmpty)
	}

	private var canSend: Bool { !Addresses.parse(draft.to).isEmpty && !store.identities(for: draft).isEmpty }
	private static func fittingHeight() -> CGFloat {
		let window = (NSApp.mainWindow ?? NSApp.keyWindow)?.frame.height ?? 740
		return min(660, max(460, window - 80))
	}

	private static let attachmentLimit = 10 * 1024 * 1024

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text(draft.title)
					.font(Typography.bodySemibold).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
				TitlebarIconButton(icon: .minimize, help: "Minimize (keeps what you wrote)") { if hasChanges { store.minimize(draft) } else { store.compose = nil } }
			}
			.padding(.horizontal, 12).padding(.leading, 4).padding(.vertical, 8)
			rule

			// Headers, then the body and its tools, flat on the window with hairlines between.
			if store.identities(for: draft).count > 1 {
				fromRow
				rule
			}
			recipientField("To", text: $draft.to, trailing: AnyView(ccToggles))
			rule
			if showCc {
				field("Cc", text: $draft.cc)
				rule
			}
			if showBcc {
				field("Bcc", text: $draft.bcc)
				rule
			}
			field("Subject", text: $draft.subject)
			rule
			// Above the editor (a web view), so tooltips and the link popover are not drawn under it.
			formattingBar.zIndex(3)
			ComposerEditor(initialHTML: draft.body, controller: controller, onChange: { draft.body = $0 }, onFiles: addFiles)
				.frame(minHeight: 140, maxHeight: .infinity)
			if !draft.quotedHTML.isEmpty { quoted }
			if !draft.attachments.isEmpty {
				rule
				attachmentChips
			}

			if let error {
				Text(error).font(Typography.notice).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 16).padding(.bottom, 6)
			}

			if promptOpen { promptBar.zIndex(4) }

			// Its tooltips and the templates dropdown open upward over everything above.
			actionBar
				.padding(.horizontal, 16).padding(.vertical, 12)
				.zIndex(5)
		}
		.frame(width: 680, height: height)
		.background(AppTheme.background)
		.overlay { if isDropTarget { Rectangle().stroke(Color.accentColor, lineWidth: 2) } }
		.attachmentDrop(isTargeted: $isDropTarget) { addFiles($0) }
		.alert("Save as Template", isPresented: $saveTemplateOpen) {
			TextField("Title", text: $templateTitle)
			Button("Save") { store.templates.add(title: templateTitle, html: draft.body) }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Saves the message body so you can insert it in later messages.")
		}
	}

	/// Cc and Bcc, at the end of the To row: each shows or hides its own field.
	private var ccToggles: some View {
		HStack(spacing: 4) {
			toggleButton("Cc", isOn: showCc) { showCc.toggle() }
			toggleButton("Bcc", isOn: showBcc) { showBcc.toggle() }
		}
	}

	private func toggleButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Text(title).font(Typography.notice)
				.foregroundStyle(isOn ? Color.primary : Color.secondary)
				.padding(.horizontal, 7).padding(.vertical, 3)
				.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? AppTheme.railSelection : .clear))
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(isOn ? "Hide \(title)" : "Show \(title)")
	}

	// MARK: Body tools

	/// The quoted original is re-colored for the dark window when it has no dark styles of its own.
	private var quoteNeedsAdapting: Bool {
		colorScheme == .dark && !draft.quotedHTML.isEmpty && !MessageAppearance.supportsDark(draft.quotedHTML)
	}

	private var formattingBar: some View {
		FormattingToolbar(controller: controller) {
			// Same state as the reader's colors button: shown where the quoted mail has no dark styles.
			if quoteNeedsAdapting {
				TitlebarIconButton(
					icon: .colors,
					help: store.adaptColors ? "Show Original Colors" : "Adapt Colors to Dark Mode",
					isActive: !store.adaptColors
				) { store.toggleAdaptColors() }
			}
			TitlebarIconButton(icon: .attachment, help: "Attach files (up to 10 MB each)", tooltipTrailing: true) { attach() }
		}
		.padding(.horizontal, 12).padding(.vertical, 4)
	}

	/// The quoted original, folded behind a toggle as in the web composer.
	private var quoted: some View {
		VStack(alignment: .leading, spacing: 0) {
			Button { withAnimation(.snappy(duration: 0.2)) { showQuoted.toggle() } } label: {
				HStack(spacing: 6) {
					HIcon(.chevronRight, size: 10).rotationEffect(.degrees(showQuoted ? 90 : 0))
					Text(showQuoted ? "Hide quoted text" : "Show quoted text").font(Typography.notice)
				}
				.foregroundStyle(.secondary)
				.padding(.horizontal, 16).padding(.vertical, 6)
				.frame(maxWidth: .infinity, alignment: .leading)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			if showQuoted {
				ScrollView {
					MessageWebView(html: draft.quotedHTML, mode: quoteNeedsAdapting ? (store.adaptColors ? .adapted : .original) : .asIs, contentHeight: $quotedHeight)
						.frame(height: max(quotedHeight, 40))
				}
				.frame(height: min(max(quotedHeight, 40), 200))
			}
		}
	}

	private var attachmentChips: some View {
		ScrollView(.horizontal) {
			HStack(spacing: 8) {
				ForEach(draft.attachments) { a in
					let isImage = a.mimeType.hasPrefix("image/") && a.filePath != nil
					HStack(spacing: 6) {
						if isImage, let path = a.filePath { AttachmentThumb(path: path) } else { HIcon(.attachment, size: 13) }
						Text(a.name).font(Typography.notice).lineLimit(1)
						Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
							.font(Typography.meta).foregroundStyle(.secondary)
						Button { draft.attachments.removeAll { $0.id == a.id } } label: { HIcon(.close, size: 11) }
							.buttonStyle(.light).foregroundStyle(.secondary)
					}
					.padding(.leading, isImage ? 3 : 14).padding(.trailing, 14).padding(.vertical, isImage ? 3 : 10)
					.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
				}
			}
			.padding(10)
		}
	}

	// MARK: Actions

	private var actionBar: some View {
		HStack(spacing: 8) {
			Button("Discard") { writeTask?.cancel(); store.compose = nil }.buttonStyle(.pill)
			TitlebarIconButton(
				icon: .sparkles,
				help: aiReady ? "AI Writer" : "Set AI Provider to enable AI Writer",
				isActive: promptOpen,
				isDimmed: !aiReady,
				tooltipAbove: true
			) { if aiReady { togglePrompt() } }
			Spacer()
			Button("Save Draft") { run(send: false) }.buttonStyle(.pill)
			sendButton
		}
	}

	// MARK: AI Writer

	private var aiReady: Bool { store.ai.writerClient != nil }

	private func togglePrompt() {
		withAnimation(.snappy(duration: 0.2)) { promptOpen.toggle() }
		if promptOpen { promptFocused = true } else { writeTask?.cancel(); controller.focus() }
	}

	/// The prompt field, right above the footer buttons: Enter or the arrow writes into the body.
	private var promptBar: some View {
		HStack(spacing: 8) {
			HIcon(.sparkles, size: 14).foregroundStyle(.secondary)
			TextField(draft.body.isEmpty ? "Describe the message to write…" : "Tell AI how to change this message…", text: $prompt)
				.textFieldStyle(.plain).font(Typography.body)
				.focused($promptFocused)
				.disabled(writing)
				.onSubmit(writeWithAI)
				.onExitCommand { togglePrompt() }
			if writing {
				ProgressView().controlSize(.small)
				TitlebarIconButton(icon: .close, help: "Stop") { writeTask?.cancel() }
			} else {
				TitlebarIconButton(icon: .send, help: "Write (↩)", isEnabled: !prompt.trimmingCharacters(in: .whitespaces).isEmpty) { writeWithAI() }
			}
		}
		.padding(.horizontal, 12).padding(.vertical, 6)
		.background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.railSelection.opacity(0.7)))
		.padding(.horizontal, 16).padding(.top, 4)
		.transition(.opacity)
	}

	private func writeWithAI() {
		let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !writing, !text.isEmpty, let client = store.ai.writerClient else { return }
		error = nil
		writing = true
		let snapshot = draft
		let instructions = store.ai.writerInstructions
		writeTask = Task {
			defer { writing = false }
			do {
				let html = try await AIWriter.write(client: client, prompt: text, draft: snapshot, instructions: instructions)
				guard !Task.isCancelled else { return }
				controller.replaceAll(html: html)
				prompt = ""
			} catch is CancellationError {
			} catch {
				self.error = describe(error)
			}
		}
	}

	/// Send, with a menu beside it for templates, as in the web composer.
	private var sendButton: some View {
		HStack(spacing: 0) {
			Button(action: submit) {
				HStack(spacing: 5) {
					HIcon(.send, size: 13)
					Text("Send")
				}
				.padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 7)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.keyboardShortcut(.return, modifiers: .command)
			.disabled(!canSend)
			Rectangle().fill(AppTheme.prominentPillText.opacity(0.25)).frame(width: 1, height: 18)
			Button {
				withAnimation(.snappy(duration: 0.2)) { sendMenuOpen.toggle() }
			} label: {
				HIcon(.chevronDown, size: 12).padding(.horizontal, 9).padding(.vertical, 7).contentShape(Rectangle())
					.rotationEffect(.degrees(sendMenuOpen ? 180 : 0))
			}
			.buttonStyle(.plain)
			.help("Templates")
		}
		.font(.system(size: 13, weight: .medium))
		.foregroundStyle(AppTheme.prominentPillText)
		.background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.prominentPillFill))
		.opacity(canSend ? 1 : 0.45)
		// The dropdown opens upward from the chevron.
		.overlay(alignment: .bottomTrailing) {
			if sendMenuOpen { sendDropdown.offset(y: -42) }
		}
		.clickAway(isActive: sendMenuOpen) { closeSendMenu() }
	}

	private func closeSendMenu() { withAnimation(.snappy(duration: 0.2)) { sendMenuOpen = false } }

	private var sendDropdown: some View {
		DropdownCard(width: 270, anchor: .bottomTrailing) {
			DropdownLabel(title: "Templates")
			let items = store.templates.items
			if items.isEmpty {
				DropdownRow(label: "No templates yet", isEnabled: false) {}
			} else {
				ScrollView {
					VStack(spacing: 2) {
						ForEach(items) { template in
							DropdownRow(label: template.title, onDelete: { store.templates.remove(template.id) }) {
								apply(template)
								closeSendMenu()
							}
						}
					}
				}
				.frame(height: min(CGFloat(items.count) * 34, 204))
			}
			DropdownDivider()
			DropdownRow(label: "Save Message as Template…", icon: .add, isEnabled: !draft.body.isEmpty) {
				templateTitle = draft.subject
				closeSendMenu()
				saveTemplateOpen = true
			}
		}
	}

	// MARK: From

	private var fromLabel: String {
		let identity = store.identities(for: draft).first { $0.id == draft.identityID } ?? store.identities(for: draft).first
		return identity.map { $0.name.isEmpty ? $0.email : "\($0.name) <\($0.email)>" } ?? ""
	}

	/// Like a Settings dropdown: the label on the left, then the choice across the rest of the row
	/// with its chevron at the far right, opening the same card below it.
	private var fromRow: some View {
		HStack(spacing: 0) {
			label("From")
			FromPickerButton(text: fromLabel, isOpen: fromOpen) {
				withAnimation(.snappy(duration: 0.2)) { fromOpen.toggle() }
			}
			.overlay(alignment: .topLeading) {
				if fromOpen {
					DropdownCard(width: nil, anchor: .topLeading) {
						ForEach(store.identities(for: draft)) { identity in
							DropdownRow(
								label: identity.name.isEmpty ? identity.email : "\(identity.name) <\(identity.email)>",
								isSelected: identity.id == (draft.identityID ?? store.identities(for: draft).first?.id)
							) {
								draft.identityID = identity.id
								withAnimation(.snappy(duration: 0.2)) { fromOpen = false }
							}
						}
					}
					.offset(y: 32)
				}
			}
			.clickAway(isActive: fromOpen) { withAnimation(.snappy(duration: 0.2)) { fromOpen = false } }
		}
		.padding(.horizontal, 16).padding(.vertical, 5)
		.zIndex(fromOpen ? 10 : 0)
	}

	private func apply(_ template: ComposeTemplates.Template) {
		if draft.subject.trimmingCharacters(in: .whitespaces).isEmpty { draft.subject = template.title }
		controller.insert(html: template.html)
	}

	private func submit() {
		error = nil
		do {
			try store.commit(draft, send: true)
		} catch { self.error = describe(error) }
	}

	private func run(send: Bool) {
		error = nil
		do { try store.commit(draft, send: send) } catch { self.error = describe(error) }
	}

	// MARK: Fields

	private var rule: some View { Rectangle().fill(AppTheme.cardStroke).frame(height: 1).padding(.horizontal, 16) }

	private func label(_ text: String) -> some View {
		Text(text).font(Typography.notice).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
	}

	private func field(_ title: String, text: Binding<String>, trailing: AnyView? = nil) -> some View {
		HStack {
			label(title)
			TextField("", text: text).textFieldStyle(.plain).font(Typography.body)
			if let trailing { trailing }
		}
		.padding(.horizontal, 16).padding(.vertical, 9)
	}

	/// To field with contact suggestions for the address being typed.
	private func recipientField(_ title: String, text: Binding<String>, trailing: AnyView? = nil) -> some View {
		let last = text.wrappedValue.split(separator: ",", omittingEmptySubsequences: false).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
		let suggestions = store.suggestions(last).filter { !text.wrappedValue.contains($0.email) }
		return VStack(spacing: 0) {
			field(title, text: text, trailing: trailing)
			if !suggestions.isEmpty {
				HStack(spacing: 6) {
					ForEach(suggestions) { s in
						Button(s.formatted) {
							var parts = text.wrappedValue.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
							parts[parts.count - 1] = s.formatted
							text.wrappedValue = parts.joined(separator: ", ") + ", "
						}
						.buttonStyle(.pill)
					}
					Spacer()
				}
				.padding(.horizontal, 16).padding(.bottom, 8)
			}
		}
	}

	// MARK: Attachments

	private func attach() {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = true
		guard panel.runModal() == .OK else { return }
		addFiles(panel.urls)
	}

	/// Adds files as attachments, skipping folders, repeats and anything over the upload limit.
	private func addFiles(_ urls: [URL]) {
		for url in urls {
			let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
			if values?.isDirectory == true { error = "\(url.lastPathComponent) is a folder. Compress it first."; continue }
			if draft.attachments.contains(where: { $0.filePath == url.path }) { continue }
			let size = values?.fileSize ?? 0
			if size > Self.attachmentLimit { error = "\(url.lastPathComponent) is over the 10 MB upload limit."; continue }
			let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
			draft.attachments.append(OutgoingAttachment(filePath: url.path, blobId: nil, name: url.lastPathComponent, mimeType: type, size: UInt64(size)))
		}
	}
}

/// The From choice: its text, and a chevron at the far end, on a soft fill when hovered or open.
private struct FromPickerButton: View {
	var text: String
	var isOpen: Bool
	var action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				Text(text).font(Typography.body).lineLimit(1)
				Spacer(minLength: 8)
				HIcon(.chevronDown, size: 12).foregroundStyle(.secondary).rotationEffect(.degrees(isOpen ? 180 : 0))
			}
			.padding(.horizontal, 8).padding(.vertical, 4)
			.frame(maxWidth: .infinity)
			.background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovering || isOpen ? AppTheme.rowHighlight : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
	}
}
