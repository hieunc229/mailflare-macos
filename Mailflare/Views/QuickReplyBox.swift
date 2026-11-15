import SwiftUI
import ImageIO
import MailflareCore

/// The reply field held at the bottom of the reader, styled as an input. Inactive it is one line (the
/// reply so far, or a prompt) with Send at its end; a click or focus opens it with the formatting tools
/// and an editor that grows with the text up to four lines, then scrolls. A click anywhere else, or
/// Escape, folds it again. What is written is kept per message (`QuickReplies`) until it is sent.
struct QuickReplyBox: View {
	@Environment(MailStore.self) private var store
	let message: MessageSummary
	@Binding var attachments: [OutgoingAttachment]
	@Binding var error: String?

	@State private var isActive = false
	@State private var html = ""
	/// The editor's text height, as it reports it.
	@State private var textHeight: CGFloat = Self.lineHeight
	/// The editor web view has loaded; until then the one-line text stands in for it.
	@State private var editorReady = false
	@State private var controller = ComposerController()
	/// The reply is on its way: Send shows a spinner and does nothing until it is sent or fails.
	@State private var sending = false
	/// The AI prompt list is open, or a rewrite is running; the box stays open for both.
	@State private var aiMenuOpen = false
	@State private var aiRunning = false

	/// One line of the editor's 14 px text at its 1.45 line height.
	static let lineHeight: CGFloat = 21
	private static let maxLines: CGFloat = 4
	private static let animation = Animation.snappy(duration: 0.22)
	private static let sendSize: CGFloat = 28
	/// The folded card: one line between its top and bottom padding. Send is centred in it.
	private static let inactiveHeight: CGFloat = lineHeight + 8 + 10

	private var key: String { store.quickReplyKey(message.id) }
	private var isBlank: Bool { PreviewText.plain(html).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
	/// A reply needs words or a file to go.
	private var canSend: Bool { !isBlank || !attachments.isEmpty }
	private var placeholder: String { "Reply to \(message.senderDisplay)…" }
	private var editorHeight: CGFloat { min(max(textHeight, Self.lineHeight), Self.lineHeight * Self.maxLines) }

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			if isActive {
				FormattingToolbar(controller: controller, iconSize: RailMetrics.iconSize - 2)
					.withLeading(AIPromptMenu(
						controller: controller, html: html, message: message, iconSize: RailMetrics.iconSize - 2,
						isOpen: $aiMenuOpen, isRunning: $aiRunning))
					.padding(.horizontal, -4)
					.transition(.opacity)
			}
			if !attachments.isEmpty { attachmentChips }
			if let error { Text(error).font(Typography.meta).foregroundStyle(.red) }
			ZStack(alignment: .topLeading) {
				if !isActive || !editorReady { summaryLine }
				if isActive { editor }
			}
			// Clear of the Send button floating over the corner.
			.padding(.trailing, Self.sendSize + 6)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		// A little more below than above, so the line sits centred in the card.
		.padding(.leading, 14).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 10)
		.background(AppTheme.composerFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isActive ? AppTheme.outline : AppTheme.composerStroke, lineWidth: 1))
		.overlay(alignment: .bottomTrailing) { sendButton.padding(.trailing, 6).padding(.bottom, (Self.inactiveHeight - Self.sendSize) / 2) }
		.contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
		.onTapGesture { if isActive { controller.focus() } else { activate() } }
		.background(OutsideClickMonitor(isActive: isActive && !aiMenuOpen && !aiRunning) { deactivate() })
		.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
		.onAppear { html = store.quickReplies.reply(for: key) }
		.onChange(of: attachments.count) { old, new in if new > old { activate() } }
		.attachmentDrop { addFiles($0) }
	}

	private func addFiles(_ urls: [URL]) {
		let result = AttachmentFiles.make(from: urls, existing: attachments)
		attachments += result.attachments
		error = result.error
	}

	private var attachmentChips: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				ForEach(attachments) { a in
					let isImage = a.mimeType.hasPrefix("image/") && a.filePath != nil
					HStack(spacing: 6) {
						if a.mimeType.hasPrefix("image/"), let path = a.filePath {
							Button { edit(a, path) } label: {
								AttachmentThumb(path: path).overlay(alignment: .bottomTrailing) {
									Image(systemName: "pencil.circle.fill").font(.system(size: 12)).foregroundStyle(.white, .black.opacity(0.6)).offset(x: 3, y: 3)
								}
							}
							.buttonStyle(.plain).help("Preview and edit")
						} else {
							HIcon(.attachment, size: 13)
						}
						Text(a.name).font(Typography.notice).lineLimit(1)
						Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
							.font(Typography.meta).foregroundStyle(.secondary)
						Button { attachments.removeAll { $0.id == a.id } } label: { HIcon(.close, size: 11) }
							.buttonStyle(.light).foregroundStyle(.secondary)
					}
					.padding(.leading, isImage ? 3 : 14).padding(.trailing, 14).padding(.vertical, isImage ? 3 : 10)
					.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
				}
			}
		}
	}

	/// The reply so far on one line, or the prompt when there is none.
	private var summaryLine: some View {
		Text(isBlank ? placeholder : PreviewText.plain(html))
			.font(.system(size: 14))
			.foregroundStyle(isBlank ? .tertiary : .primary)
			.lineLimit(1)
			.frame(height: Self.lineHeight)
			.allowsHitTesting(false)
	}

	private var editor: some View {
		ComposerEditor(
			initialHTML: html, controller: controller, placeholder: placeholder, fitsContent: true, autofocus: true,
			onChange: { body in
				html = body
				// In memory now; QuickReplies writes the file at most once a second.
				store.quickReplies.set(body, for: key)
			},
			onFiles: { addFiles($0) },
			onHeight: { height in
				guard abs(height - textHeight) > 0.5 else { return }
				withAnimation(Self.animation) { textHeight = height }
			},
			onReady: { editorReady = true },
			onEscape: { deactivate() }
		)
		.frame(height: editorHeight)
		.opacity(editorReady ? 1 : 0)
		.allowsHitTesting(!sending && !aiRunning)
	}

	private var sendButton: some View {
		Button(action: send) {
			Group {
				if sending { SendSpinner() } else { HIcon(.sent, size: 14) }
			}
				.foregroundStyle(AppTheme.prominentPillText)
				.frame(width: Self.sendSize, height: Self.sendSize)
				.background(Circle().fill(AppTheme.prominentPillFill))
				.contentShape(Circle())
		}
		.buttonStyle(.plain)
		.disabled(!canSend || sending || aiRunning)
		.opacity(!canSend || aiRunning ? 0.4 : 1)
		.keyboardShortcut(isActive ? KeyboardShortcut(.return, modifiers: .command) : nil)
		.help("Send Reply (⌘↩)")
	}

	/// Opens an attached image in the full-window editor; the edited copy replaces it.
	private func edit(_ a: OutgoingAttachment, _ path: String) {
		store.imageEditor = ImageEditSession(url: URL(fileURLWithPath: path), name: a.name) { url in
			guard let i = attachments.firstIndex(where: { $0.id == a.id }) else { return }
			let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
			if size > AttachmentFiles.limit { error = "The edited image is over the 10 MB upload limit."; return }
			error = nil
			attachments[i] = OutgoingAttachment(filePath: url.path, blobId: nil, name: url.lastPathComponent, mimeType: "image/png", size: UInt64(size))
		}
	}

	private func activate() {
		guard !isActive else { return }
		withAnimation(Self.animation) { isActive = true }
	}

	private func deactivate() {
		guard isActive else { return }
		withAnimation(Self.animation) {
			isActive = false
			editorReady = false
		}
	}

	private func send() {
		let body = html
		let files = attachments
		guard canSend, !sending, !aiRunning else { return }
		sending = true
		// The text stays until the reply is sent; then it leaves the box and joins the message.
		store.sendQuickReply(to: message.id, html: body, attachments: files, onSent: {
			sending = false
			attachments = []
			error = nil
			html = ""
			textHeight = Self.lineHeight
			isActive = false
			editorReady = false
		}, onFailure: { sending = false })
	}
}

/// A spinning ring in the Send button's text color, so it reads on the button's fill in both themes.
private struct SendSpinner: View {
	@State private var spinning = false

	var body: some View {
		Circle()
			.trim(from: 0, to: 0.75)
			.stroke(AppTheme.prominentPillText, style: StrokeStyle(lineWidth: 2, lineCap: .round))
			.frame(width: 14, height: 14)
			.rotationEffect(.degrees(spinning ? 360 : 0))
			.onAppear { withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true } }
	}
}

/// Reports a click in the same window outside the view it backs, without taking the click: what was
/// clicked (a link in the message, another row) still gets it. Clicks in other windows, such as the
/// toolbar's link popover, are not outside.
private struct OutsideClickMonitor: NSViewRepresentable {
	var isActive: Bool
	var onOutside: () -> Void

	func makeNSView(context: Context) -> MonitorView { MonitorView() }

	func updateNSView(_ view: MonitorView, context: Context) {
		view.isActive = isActive
		view.onOutside = onOutside
	}

	final class MonitorView: NSView {
		var isActive = false
		var onOutside: () -> Void = {}
		private var monitor: Any?

		/// Never the target of a click itself.
		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
			guard window != nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
				guard let self, self.isActive, event.window === self.window else { return event }
				if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
					DispatchQueue.main.async { self.onOutside() }
				}
				return event
			}
		}
	}
}

/// A small preview of an image file, decoded at thumbnail size off the main thread.
struct AttachmentThumb: View {
	let path: String
	@State private var image: NSImage?

	var body: some View {
		Group {
			if let image { Image(nsImage: image).resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
		}
		.frame(width: 34, height: 34)
		.clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
		.task(id: path) {
			let path = path
			image = await Task.detached {
				guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
					  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
						kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
						kCGImageSourceThumbnailMaxPixelSize: 80] as CFDictionary)
				else { return nil as NSImage? }
				return NSImage(cgImage: cg, size: .zero)
			}.value
		}
	}
}
