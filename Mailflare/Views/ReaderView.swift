import SwiftUI
import WebKit
import MailflareCore

struct ReaderView: View {
	@Environment(MailStore.self) private var store

	var body: some View {
		if store.multiSelection.count > 1 {
			EmptyStateView(icon: .inbox, title: "\(store.multiSelection.count) Messages Selected", message: "Right-click to archive, flag or delete them together.")
				.background(AppTheme.background)
		} else if let message = store.selectedMessage {
			MessageDetail(message: message).id(message.id)
		} else {
			EmptyStateView(icon: .inbox, title: "No Message Selected")
				.background(AppTheme.background)
		}
	}
}

private struct MessageDetail: View {
	@Environment(MailStore.self) private var store
	let message: MessageSummary
	@Environment(\.colorScheme) private var colorScheme
	@State private var showDetails = false
	@State private var editingContact = false
	/// The AI summary saved with this message, kept in the store so the toolbar button can make it.
	private var summary: String? { store.summaries[message.id] }
	/// Whether this sender's mail is re-colored for the dark window; the toolbar's colors button sets it.
	private var adapts: Bool { store.adaptColors }
	/// The Settings default; changing it re-derives `adapts` for the open message.
	@AppStorage(MessageAppearance.adaptKey) private var adaptByDefault = true

	/// The message body's height once laid out; the web view is sized to it so the header, the body
	/// and the attachments scroll together as one page.
	@State private var webHeight: CGFloat = 0
	/// Remote content the user allowed for this message alone, where the settings would block it.
	@State private var loadRemoteOnce = false
	/// Files dropped on the message or the reply box, sent with the quick reply.
	@State private var replyAttachments: [OutgoingAttachment] = []
	@State private var dropError: String?
	@State private var isDropTarget = false
	@AppStorage(ReadingSettings.loadRemoteContentKey) private var loadRemoteContent = true

	init(message: MessageSummary) {
		self.message = message
	}

	/// The dark-only toggle shows when the body has no dark styles of its own to defer to.
	private func needsAdapting(_ html: String) -> Bool {
		colorScheme == .dark && !MessageAppearance.supportsDark(html)
	}

	private func mode(for html: String) -> MessageWebView.Mode {
		guard needsAdapting(html) else { return .asIs }
		return adapts ? .adapted : .original
	}

	private var isJunk: Bool { store.role(of: message) == "junk" }
	/// Remote images and styles load when Settings allow it, except in Junk. Where blocked (they can
	/// track opens), a button loads them for the one message.
	private var allowsRemote: Bool { (loadRemoteContent && !isJunk) || loadRemoteOnce }

	var body: some View {
		// The reply box sticks to the bottom and the message scrolls under it; a draft is edited, not
		// replied to. The fade lets the text go out behind the box instead of being cut off by it.
		content
			.safeAreaInset(edge: .bottom, spacing: 0) {
				if store.role(of: message) != "drafts" {
					QuickReplyBox(message: message, attachments: $replyAttachments, error: $dropError)
						.background {
							LinearGradient(stops: [
								.init(color: AppTheme.background.opacity(0), location: 0),
								.init(color: AppTheme.background, location: 0.45),
								.init(color: AppTheme.background, location: 1),
							], startPoint: .top, endPoint: .bottom)
							.padding(.top, -32)
						}
				}
			}
		.background(AppTheme.background)
		.overlay { if isDropTarget && store.role(of: message) != "drafts" { Rectangle().stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
		.attachmentDrop(enabled: store.role(of: message) != "drafts", isTargeted: $isDropTarget) { urls in
			let result = AttachmentFiles.make(from: urls, existing: replyAttachments)
			replyAttachments += result.attachments
			dropError = result.error
		}
		.task { store.loadSavedSummary(for: message.id) }
		.onChange(of: adaptByDefault) { _, _ in store.refreshAdaptColors() }
	}

	private var content: some View {
		ScrollViewReader { scroller in
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				VStack(alignment: .leading, spacing: 12) {
					header
					if let summary { summaryCard(summary) }
					if let error = store.summaryError { Text(error).font(Typography.meta).foregroundStyle(.orange) }
				}
				.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

				if store.detail == nil { bodySkeleton }
				if let body = store.detail {
					if body.hasRemoteContent && !allowsRemote {
						remoteContentNotice
					}
					MessageWebView(html: body.html, mode: mode(for: body.html), allowsRemote: allowsRemote, contentHeight: $webHeight)
						.frame(height: max(webHeight, 40))
					if !body.attachments.isEmpty {
						Divider().overlay(AppTheme.cardStroke)
						ScrollView(.horizontal) {
							HStack(spacing: 8) {
								ForEach(body.attachments) { a in
									Button { store.save(a) } label: {
										HStack(spacing: 6) {
											HIcon(.attachment, size: 14)
											Text(a.displayName).font(Typography.notice).lineLimit(1)
											Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
												.font(Typography.meta).foregroundStyle(.secondary)
										}
										.noticeSurface(radius: 10)
									}
									.buttonStyle(.light).help("Save \(a.displayName)…")
								}
							}
							.padding(12)
						}
					}
				}
				// Replies sent from the reply box slide in at the end, like the rest of the conversation.
				ForEach(store.sentReplies[message.id] ?? []) { reply in
					SentReplyView(reply: reply) {
						// Its text is measured after it appears, so follow the growth to the bottom.
						withAnimation(.snappy(duration: 0.3)) { scroller.scrollTo("end", anchor: .bottom) }
					}
					.transition(.move(edge: .bottom).combined(with: .opacity))
				}
				Color.clear.frame(height: 1).id("end")
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.onChange(of: store.sentReplies[message.id]?.count ?? 0) { _, _ in
			DispatchQueue.main.async { withAnimation(.snappy(duration: 0.35)) { scroller.scrollTo("end", anchor: .bottom) } }
		}
		}
	}

	/// Stands in for the message while its body loads: four lines of text.
	private var bodySkeleton: some View {
		VStack(alignment: .leading, spacing: 9) {
			ForEach(Array([1.0, 0.96, 0.9, 0.55].enumerated()), id: \.offset) { _, fraction in
				GeometryReader { proxy in SkeletonBar(width: proxy.size.width * fraction, height: 13) }.frame(height: 13)
			}
		}
		.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 20)
		.accessibilityLabel("Loading message")
	}

	private var remoteContentNotice: some View {
		HStack(spacing: 10) {
			Text(isJunk ? "Remote content is blocked in Junk." : "Remote content is blocked.")
				.font(Typography.notice).foregroundStyle(.secondary)
			Spacer(minLength: 8)
			Button("Load Remote Content") { loadRemoteOnce = true }.buttonStyle(.pill)
		}
		.noticeSurface(radius: 12)
		.padding(.horizontal, 20).padding(.vertical, 4)
	}

	/// The saved AI summary, in a bordered container above the content.
	private func summaryCard(_ text: String) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				HIcon(.aiContent, size: 13)
				Text("Summary").font(Typography.meta.weight(.medium))
			}
			.foregroundStyle(.secondary)
			Text(text).font(Typography.body).textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.padding(12)
		.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.outline, lineWidth: 1))
	}

	/// The sender and recipients, each with their address beside their name.
	private var header: some View {
		let to = store.detail?.to ?? []
		let cc = store.detail?.cc ?? []
		return HStack(alignment: .top, spacing: 10) {
			// Opens the sender's profile: picture, name and description.
			Button { editingContact = true } label: {
				SenderAvatar(email: message.fromEmail, name: message.senderDisplay, size: 36)
			}
			.buttonStyle(.plain).help("Edit contact")
			.popover(isPresented: $editingContact, arrowEdge: .bottom) { ContactEditor(contact: message.sender) }
			VStack(alignment: .leading, spacing: 3) {
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					senderLine
					Spacer(minLength: 8)
					if store.role(of: message) == "drafts" {
						Button("Edit Draft") { store.editDraft(message.id) }.buttonStyle(.pill)
					}
					if message.hasAttachment { HIcon(.attachment, size: 13).foregroundStyle(.secondary) }
					if message.flagged { HIcon(.flag, size: 13).foregroundStyle(.orange) }
					Text(MailDate.full(message.date))
						.font(Typography.meta).foregroundStyle(.secondary).lineLimit(1).fixedSize()
				}
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					if store.detail == nil {
						// Recipients arrive with the body.
						SkeletonBar(width: 220, height: 10).padding(.vertical, 3)
					} else {
						Text(recipientLine("To", to))
							.font(Typography.notice).foregroundStyle(.secondary)
							.lineLimit(showDetails ? nil : 1).truncationMode(.tail)
							.textSelection(.enabled)
						// Right after the last recipient, not at the far edge.
						Button(showDetails ? "Hide" : "Details") { showDetails.toggle() }
							.buttonStyle(.light).font(Typography.notice).foregroundStyle(Color.accentColor)
							.fixedSize()
					}
					Spacer(minLength: 0)
				}
				// Cc has its own line. (The core does not return Bcc for received mail.)
				if !cc.isEmpty {
					Text(recipientLine("Cc", cc))
						.font(Typography.notice).foregroundStyle(.secondary)
						.lineLimit(showDetails ? nil : 1).truncationMode(.tail)
						.textSelection(.enabled)
				}
				if showDetails {
					VStack(alignment: .leading, spacing: 2) {
						Text("From: \(message.sender.formatted)")
						Text("Date: \(message.date.formatted(date: .complete, time: .shortened))")
					}
					.font(Typography.meta).foregroundStyle(.secondary).textSelection(.enabled)
				}
			}
		}
	}

	/// "Name  address", the name bold and the address quieter; just the address when there is no name.
	/// A name given to the contact on this Mac replaces the sender's own. Clicking opens the contact.
	private var senderLine: some View {
		let name = store.contacts.name(for: message.fromEmail) ?? message.senderDisplay
		let address = message.fromEmail
		let named = !name.isEmpty && name.lowercased() != address.lowercased()
		return Button { editingContact = true } label: {
			(Text(named ? name : address).font(Typography.bodySemibold)
				+ Text(named ? "  \(address)" : "").font(Typography.notice).foregroundStyle(.secondary))
				.lineLimit(1).truncationMode(.tail)
		}
		.buttonStyle(.plain)
	}

	/// "To: Name <address>, …" or "Cc: …", every recipient with its address.
	private func recipientLine(_ label: String, _ people: [EmailAddress]) -> String {
		"\(label): " + people.map(\.formatted).joined(separator: ", ")
	}
}

/// A reply sent from the reply box, shown after the message with the same parts: who it is from, who
/// it went to, when, and the text.
private struct SentReplyView: View {
	@Environment(MailStore.self) private var store
	let reply: MailStore.SentReply
	/// Called when the text's height is known or changes.
	var onSized: () -> Void = {}
	@State private var height: CGFloat = 0

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Divider().overlay(AppTheme.cardStroke)
			HStack(alignment: .top, spacing: 10) {
				ProfileAvatar(
					key: AvatarCache.key(account: reply.accountID),
					name: store.accountList.first { $0.id == reply.accountID }.map(store.accountName) ?? "Me", size: 36)
				VStack(alignment: .leading, spacing: 3) {
					HStack(alignment: .firstTextBaseline, spacing: 6) {
						Text("You").font(Typography.bodySemibold)
						Spacer(minLength: 8)
						Text(MailDate.full(reply.date)).font(Typography.meta).foregroundStyle(.secondary).lineLimit(1).fixedSize()
					}
					Text("To: \(reply.to)").font(Typography.notice).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
				}
			}
			.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
			MessageWebView(html: reply.html, mode: .asIs, contentHeight: $height)
				.frame(height: max(height, 40))
		}
		.onChange(of: height) { _, _ in onSized() }
	}
}

struct Avatar: View {
	let contact: EmailAddress
	var size: CGFloat = 32

	var body: some View {
		Text(contact.initials)
			.font(.system(size: size * 0.38, weight: .semibold))
			.foregroundStyle(.primary)
			.frame(width: size, height: size)
			.background(AppTheme.railSelection, in: Circle())
	}
}

/// A web view that never scrolls on its own: scroll gestures go to the scroll view around it, and
/// it reports its content's height so it can be sized to show all of it.
private final class PassthroughWebView: WKWebView {
	override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
	/// The reader takes no drops itself; leaving them to the page would swallow dropped files.
	override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
}

/// Renders mail HTML with JavaScript off. Remote images, styles and fonts load only when
/// `allowsRemote` is set; otherwise a CSP blocks every remote load. (The height is read
/// with a script the app runs itself; that is not the page's JavaScript, which stays off.)
struct MessageWebView: NSViewRepresentable {
	/// `asIs` follows the app theme (light mode, or mail with its own dark styles); `adapted` runs
	/// `MessageAppearance`'s re-coloring; `original` shows the sender's light design on a white page.
	enum Mode { case asIs, adapted, original }

	let html: String
	let mode: Mode
	var allowsRemote = false
	@Binding var contentHeight: CGFloat

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.defaultWebpagePreferences.allowsContentJavaScript = false
		config.userContentController.addUserScript(MessageAppearance.userScript)
		let view = PassthroughWebView(frame: .zero, configuration: config)
		view.navigationDelegate = context.coordinator
		view.unregisterDraggedTypes()
		view.setValue(false, forKey: "drawsBackground")
		view.postsFrameChangedNotifications = true
		context.coordinator.observe(view)
		return view
	}

	func updateNSView(_ view: WKWebView, context: Context) {
		let height = $contentHeight
		context.coordinator.onHeight = { h in if abs(height.wrappedValue - h) > 0.5 { height.wrappedValue = h } }
		let key = "\(mode)\u{0}\(allowsRemote)\u{0}\(html)"
		guard context.coordinator.loaded != key else { return }
		context.coordinator.loaded = key
		let csp = allowsRemote
			? "default-src 'none'; img-src data: cid: http: https:; style-src 'unsafe-inline' http: https:; font-src data: http: https:; media-src http: https:"
			: "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"
		// Adapted pages stay hidden until the script has re-colored them, so they never flash light.
		let htmlTag = mode == .adapted ? #"<html data-adapt="1" style="visibility:hidden">"# : "<html>"
		let scheme = mode == .original ? "light" : "light dark"
		let paper = mode == .original ? "html{background:#fff}" : ""
		let doc = """
		<!doctype html>\(htmlTag)<head><meta charset="utf-8">
		<meta http-equiv="Content-Security-Policy" content="\(csp)">
		<meta name="color-scheme" content="\(scheme)">
		<style>html,body{margin:0;padding:0;overflow-x:hidden}\(paper)
		#c{font:14px -apple-system,system-ui;padding:16px 20px;word-wrap:break-word;overflow-wrap:anywhere}
		img{max-width:100%;height:auto}pre{font-family:inherit;white-space:pre-wrap}</style></head><body><div id="c">\(html)</div></body></html>
		"""
		view.loadHTMLString(doc, baseURL: nil)
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	final class Coordinator: NSObject, WKNavigationDelegate {
		var loaded = ""
		var onHeight: (CGFloat) -> Void = { _ in }
		private var lastWidth: CGFloat = 0
		private var observer: NSObjectProtocol?

		/// A new width reflows the text, so the height is read again.
		func observe(_ view: WKWebView) {
			observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self, weak view] _ in
				guard let self, let view, abs(view.frame.width - self.lastWidth) > 0.5 else { return }
				self.lastWidth = view.frame.width
				self.measure(view)
			}
		}

		deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

		/// Re-coloring has run by now; the page is shown even if it failed, then measured.
		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			webView.evaluateJavaScript("document.documentElement.style.removeProperty('visibility')", in: nil, in: .defaultClient) { _ in }
			measure(webView)
		}

		/// Mail with fixed-width layouts (tables, wide images) is zoomed down to the view's width
		/// instead of scrolling sideways; narrower content stays full size. Returns the wrapper's
		/// own height, which does not stretch to the view's, so it can shrink again.
		private static let fitScript = """
		(function(){
		var c=document.getElementById('c')||document.body;
		c.style.zoom='';
		var w=document.documentElement.clientWidth,s=c.scrollWidth;
		if(w>0&&s>w+1){c.style.zoom=String(w/s);}
		return c.getBoundingClientRect().height;
		})()
		"""

		func measure(_ view: WKWebView) {
			view.evaluateJavaScript(Self.fitScript) { [weak self] result, _ in
				guard let height = (result as? NSNumber)?.doubleValue, height > 0 else { return }
				DispatchQueue.main.async { self?.onHeight(CGFloat(height.rounded(.up))) }
			}
		}

		func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
			if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") {
				NSWorkspace.shared.open(url)
				return .cancel
			}
			return action.navigationType == .other ? .allow : .cancel
		}
	}
}


/// Starts WebKit's content process before the first message is opened, so that message does not pay
/// for it. A web view loads an empty page and is let go a few seconds later.
@MainActor
enum WebViewWarmup {
	private static var view: WKWebView?

	static func run() {
		guard view == nil else { return }
		let config = WKWebViewConfiguration()
		config.defaultWebpagePreferences.allowsContentJavaScript = false
		let warm = WKWebView(frame: .zero, configuration: config)
		warm.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
		view = warm
		Task {
			try? await Task.sleep(for: .seconds(5))
			view = nil
		}
	}
}
