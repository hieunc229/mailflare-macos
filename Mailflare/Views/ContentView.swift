import SwiftUI
import MailflareCore

struct RootView: View {
	@Environment(MailStore.self) private var store

	var body: some View {
		Group {
			switch store.phase {
			case .ready: ContentView()
			// No account: the sign-in form sits alone in the middle of the window, with no popup.
			case .signedOut:
				ZStack {
					AppTheme.background
					SignInView(isPopup: false)
				}
				.ignoresSafeArea()
			case .connecting: AppTheme.background
			}
		}
		// Hidden only while the saved account is being looked for, so neither view flashes up first.
		.background(WindowVisibility(isVisible: store.phase != .connecting))
		.background(MovableByBackground(isOn: store.phase == .signedOut))
	}
}

/// Lets the window be dragged by its empty background, for the sign-in screen, which has no titlebar to grab.
private struct MovableByBackground: NSViewRepresentable {
	var isOn: Bool

	final class Host: NSView {
		var isOn = false { didSet { window?.isMovableByWindowBackground = isOn } }
		override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.isMovableByWindowBackground = isOn }
	}

	func makeNSView(context: Context) -> Host { Host() }
	func updateNSView(_ view: Host, context: Context) { view.isOn = isOn }
}

/// The window: a translucent chrome holding the titlebar band and the sidebar, with
/// one rounded card set into it for the message list and the reader.
struct ContentView: View {
	@Environment(MailStore.self) private var store
	@State private var isSidebarVisible = true
	/// Whether the sidebar was showing when the assistant expanded, so shrinking it brings it back.
	@State private var sidebarBeforeExpand: Bool?
	@State private var windowWidth: CGFloat = 0
	/// The sidebar shown over the content, when the window is too narrow to dock it.
	@State private var drawerOpen = false
	@AppStorage("listWidth") private var listWidth: Double = 330
	@AppStorage("sidebarWidth") private var sidebarWidth: Double = 264
	@AppStorage(NotificationSettings.enabledKey) private var notificationsOn = true
	@State private var listWidthAtDragStart: Double?
	@State private var sidebarWidthAtDragStart: Double?
	@FocusState private var searchFocused: Bool
	@State private var moreOpen = false
	@Environment(\.colorScheme) private var colorScheme
	@AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

	/// Dark Glass: the columns stay light inside the dark window.
	private var columnScheme: ColorScheme? { (AppAppearance(rawValue: appearance) ?? .system).lightColumns ? .light : nil }

	/// The window's own width is what the columns are laid out for. It is read from a reader that sits
	/// outside the content: the content's own size cannot be used, because it can never be less than
	/// its columns need, so a window narrower than that would be measured as wide as the columns.
	var body: some View {
		GeometryReader { proxy in
			mainContent
				.frame(width: proxy.size.width, height: proxy.size.height)
				.onChange(of: proxy.size.width, initial: true) { _, width in windowWidth = width }
		}
	}

	@ViewBuilder
	private var mainContent: some View {
		@Bindable var store = store
		let inset = WindowChromeMetrics.cardInset
		let total = windowWidth > 0 ? windowWidth : 1180
		let expanded = store.chatFillsWindow && layout.chatDocked
		// Expanded, the sidebar can stay beside the assistant; the toggle shows and hides it.
		let sideDocked = sidebarDocked
		let sideW = dockedSidebarW
		let keptSidebar = expanded && sideDocked
		// The mail columns' own width: the window less the assistant's usual column.
		let mailWidth = max(0, total - (store.chatVisible && layout.chatDocked ? AIChatPanel.width + inset : 0))
		// Expanded, the assistant takes the whole window, less the same inset on its left as on its right.
		let chatWidth = expanded ? max(AIChatPanel.width, total - inset * 2 - (keptSidebar ? sideW : 0)) : AIChatPanel.width
		HStack(spacing: 0) {
			HStack(spacing: 0) {
				if sideDocked {
					SidebarView()
						.frame(width: sideW)
						// A grab handle on the sidebar's trailing edge, over its empty gutter.
						.overlay(alignment: .trailing) {
							ResizeHandle { translation in
								if sidebarWidthAtDragStart == nil { sidebarWidthAtDragStart = sidebarWidth }
								sidebarWidth = min(380, max(220, (sidebarWidthAtDragStart ?? sidebarWidth) + Double(translation)))
							} onEnded: { sidebarWidthAtDragStart = nil }
						}
						.transition(.move(edge: .leading).combined(with: .opacity))
				}
				card
					.padding(.leading, sideDocked ? 0 : inset)
					.padding(.trailing, inset)
					.padding(.bottom, inset)
			}
			// Laid out at its own width and anchored to the trailing edge, so when the assistant expands
			// the columns slide out to the left as it grows, instead of squeezing.
			.frame(width: mailWidth)
			.frame(width: expanded ? (keptSidebar ? sideW : 0) : mailWidth, alignment: keptSidebar ? .leading : .trailing)
			.clipped()
			.allowsHitTesting(!expanded || keptSidebar)
			if store.ai.isConfigured && layout.chatDocked {
				// Always mounted so closing can play out: the column's width animates and clips the panel.
				AIChatPanel(panelWidth: chatWidth)
					.environment(\.colorScheme, columnScheme ?? colorScheme)
					.padding(.bottom, inset)
					.padding(.leading, expanded ? inset : 0)
					.frame(width: chatWidth + inset + (expanded ? inset : 0), alignment: .leading)
					.frame(width: store.chatVisible ? chatWidth + inset + (expanded ? inset : 0) : 0, alignment: .leading)
					.clipped()
					.allowsHitTesting(store.chatVisible)
			}
		}
		.padding(.top, WindowChromeMetrics.titlebarHeight)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background { ZStack { WindowVibrancy(); AppTheme.chrome } }
		.overlay(alignment: .topLeading) { sidebarDrawer }
		.overlay(alignment: .topTrailing) { floatingChat }
		.overlay(alignment: .topLeading) { titlebarLeading }
		.overlay(alignment: .topLeading) { if store.settingsPage == nil && !store.chatFillsWindow && (narrowChat || !(layout.single && store.selectedID != nil)) { titlebarSearch } }
		.overlay(alignment: .topTrailing) { if store.settingsPage == nil && !store.chatFillsWindow { titlebarTrailing } }
		.overlay(alignment: .topTrailing) { if store.ai.isConfigured { assistantToggle } }
		.animation(.easeInOut(duration: 0.2), value: store.chatOpen)
		.animation(.easeInOut(duration: 0.28), value: store.chatExpanded)
		.animation(.easeInOut(duration: 0.2), value: isSidebarVisible)

		.onChange(of: store.chatFillsWindow) { _, fills in
			// Expanding pushes every column aside, the sidebar too; the toggle can bring it back.
			if fills {
				sidebarBeforeExpand = isSidebarVisible
				isSidebarVisible = false
				drawerOpen = false
			} else if let before = sidebarBeforeExpand {
				isSidebarVisible = before
				sidebarBeforeExpand = nil
			}
		}
		.onChange(of: layout.showSidebar) { _, docked in if docked { drawerOpen = false } }
		.onChange(of: store.sidebar) { _, _ in drawerOpen = false }
		.onChange(of: store.settingsPage) { _, _ in drawerOpen = false }
		.ignoresSafeArea()
		.coordinateSpace(name: "mailflareRoot")
		// Dropdowns that must sit above every pane, web views included.
		.overlay(alignment: .topLeading) { if let menu = store.overlayMenu { OverlayMenuHost(menu: menu) } }
		// An empty toolbar keeps the unified titlebar band, which centres the traffic lights on
		// `titlebarRowCenter`; everything in the band is drawn by this view.
		.toolbar { ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1) } }
		.toolbarBackground(.hidden, for: .windowToolbar)
		.overlay { if let session = store.imageEditor { ImageEditorView(session: session) { store.imageEditor = nil }.id(session.id).transition(.opacity) } }
		.sheet(item: $store.compose) { draft in ComposeView(draft: draft) }
		.sheet(isPresented: $store.showAddAccount) { SignInView(isPopup: true) }
		.sheet(item: $store.original) { message in OriginalMessageView(message: message) }
	.sheet(item: $store.inboxViewEditor) { view in
		InboxViewEditor(view: view, isNew: !store.inboxViews.contains { $0.id == view.id })
	}
		.sheet(item: $store.folderRequest) { request in FolderEditor(request: request) }
		.sheet(item: $store.customTabEditor) { tab in
			CustomTabEditor(tab: tab, isNew: !store.customTabs.contains { $0.id == tab.id })
		}
		.onChange(of: store.sidebar) { _, _ in store.sidebarChanged() }
		.onChange(of: store.unreadOnly) { _, _ in store.reload() }
		.onChange(of: store.searchText) { _, _ in store.searchChanged() }
		.overlay(alignment: .top) {
			if let banner = store.banner {
				BannerView(title: banner) { store.banner = nil }
					.padding(.top, WindowChromeMetrics.titlebarHeight + 8)
					.transition(.move(edge: .top).combined(with: .opacity))
			}
		}
		.overlay(alignment: .topTrailing) {
			if let toast = store.toast {
				ToastView(toast: toast)
					.padding(.top, WindowChromeMetrics.titlebarHeight + 8)
					.padding(.trailing, WindowChromeMetrics.cardInset + 12)
					.transition(.move(edge: .trailing).combined(with: .opacity))
			}
		}
		.animation(.easeInOut(duration: 0.2), value: store.banner)
		.animation(.easeInOut(duration: 0.2), value: store.toast)
	}

	// MARK: Layout

	/// Which columns fit, and how wide. The window never overflows: columns first squeeze to their
	/// minimum widths, then close in this order: sidebar, message list. With only the reader left,
	/// the assistant floats over it instead of docking.
	struct PaneLayout {
		var showSidebar: Bool
		var sidebarW: CGFloat
		var showList: Bool
		var listW: CGFloat
		var chatDocked: Bool
		/// One column at a time: the list, or the open message.
		var single: Bool { !showList }
	}

	/// Below this width, with the assistant open, the window holds the assistant and one other column.
	private static let chatSingleBelow: CGFloat = 1008

	/// The window is narrow with the assistant docked: a single column (the list, or the open message)
	/// beside it, and the back button next to the search field.
	private var narrowChat: Bool { layout.single && layout.chatDocked }

	private static let sidebarMin: CGFloat = 220
	private static let listMin: CGFloat = 280
	private static let readerMin: CGFloat = 320

	private var layout: PaneLayout { computeLayout(sidebar: isSidebarVisible) }

	private func computeLayout(sidebar wantSidebar: Bool) -> PaneLayout {
		let width = windowWidth > 0 ? windowWidth : 1180
		let chat = store.chatVisible ? AIChatPanel.width + WindowChromeMetrics.cardInset : 0
		let space = width - WindowChromeMetrics.cardInset * 2 - Self.readerMin - chat
		let s = CGFloat(sidebarWidth), l = CGFloat(listWidth)
		// Too narrow for the list and the message beside the assistant: one column, then the assistant.
		// Where even that column would be squeezed, the assistant floats over it as before.
		if store.chatVisible && width < Self.chatSingleBelow {
			let column = width - WindowChromeMetrics.cardInset * 2 - chat
			return PaneLayout(showSidebar: false, sidebarW: s, showList: false, listW: 0, chatDocked: column >= Self.readerMin)
		}
		if wantSidebar, space >= Self.sidebarMin + Self.listMin {
			if s + l <= space { return PaneLayout(showSidebar: true, sidebarW: s, showList: true, listW: l, chatDocked: true) }
			let slack = (s - Self.sidebarMin) + (l - Self.listMin)
			let t = slack > 0 ? min(1, (space - Self.sidebarMin - Self.listMin) / slack) : 0
			return PaneLayout(showSidebar: true, sidebarW: Self.sidebarMin + (s - Self.sidebarMin) * t,
							  showList: true, listW: Self.listMin + (l - Self.listMin) * t, chatDocked: true)
		}
		if space >= Self.listMin {
			return PaneLayout(showSidebar: false, sidebarW: s, showList: true, listW: min(l, space), chatDocked: true)
		}
		return PaneLayout(showSidebar: false, sidebarW: s, showList: false, listW: 0, chatDocked: false)
	}

	private static let expandedSidebarMin: CGFloat = 760

	/// Whether the sidebar is docked right now: beside the columns, or, with the assistant expanded,
	/// beside the assistant.
	private var sidebarDocked: Bool {
		if store.chatFillsWindow && layout.chatDocked { return isSidebarVisible && windowWidth >= Self.expandedSidebarMin }
		return layout.showSidebar
	}

	private var dockedSidebarW: CGFloat {
		store.chatFillsWindow && layout.chatDocked ? min(380, max(220, CGFloat(sidebarWidth))) : layout.sidebarW
	}

	/// Docks or undocks the sidebar when it fits; otherwise slides it over the content and back.
	private func toggleSidebar() {
		withAnimation(.easeInOut(duration: 0.2)) {
			if store.chatFillsWindow && layout.chatDocked {
				// The assistant fills the window: the sidebar sits beside it, or is hidden.
				if isSidebarVisible { isSidebarVisible = false; drawerOpen = false }
				else if windowWidth >= Self.expandedSidebarMin { isSidebarVisible = true }
				else { drawerOpen.toggle() }
			}
			else if drawerOpen { drawerOpen = false }
			else if isSidebarVisible && layout.showSidebar { isSidebarVisible = false }
			else if !isSidebarVisible && computeLayout(sidebar: true).showSidebar { isSidebarVisible = true }
			else { drawerOpen = true }
		}
	}

	/// The sidebar over the content, for windows too narrow to dock it. A click outside closes it.
	@ViewBuilder
	private var sidebarDrawer: some View {
		if drawerOpen && !sidebarDocked {
			ZStack(alignment: .topLeading) {
				Color.black.opacity(0.001).contentShape(Rectangle())
					.onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = false } }
				SidebarView()
					.frame(width: min(CGFloat(sidebarWidth), max(200, windowWidth - 60)))
					.frame(maxHeight: .infinity)
					.background { ZStack { Rectangle().fill(.regularMaterial); AppTheme.chrome } }
					.overlay(alignment: .trailing) { Rectangle().fill(AppTheme.cardStroke).frame(width: 1) }
					.shadow(color: AppTheme.composerShadow, radius: 18, x: 4)
					.padding(.top, WindowChromeMetrics.titlebarHeight)
					.transition(.move(edge: .leading))
			}
		}
	}

	/// The assistant over the reader, when only one column fits.
	@ViewBuilder
	private var floatingChat: some View {
		if store.ai.isConfigured && store.chatVisible && !layout.chatDocked {
			AIChatPanel(panelWidth: store.chatExpanded ? max(AIChatPanel.width, windowWidth - WindowChromeMetrics.cardInset * 2) : AIChatPanel.width)
				.environment(\.colorScheme, columnScheme ?? colorScheme)
				.shadow(color: AppTheme.composerShadow, radius: 18, x: -4)
				.padding(.top, WindowChromeMetrics.titlebarHeight)
				.padding(.trailing, WindowChromeMetrics.cardInset)
				.padding(.bottom, WindowChromeMetrics.cardInset)
				.transition(.move(edge: .trailing).combined(with: .opacity))
		}
	}

	// MARK: Card

	private var card: some View {
		Group {
			if let page = store.settingsPage {
				SettingsView(page: page)
			} else if layout.single {
				// One column: the list until a message is chosen, then the message.
				if store.selectedID == nil { MessageListView() } else { ReaderView() }
			} else {
				HStack(spacing: 0) {
					MessageListView()
						.frame(width: layout.listW)
					PaneDivider { translation in
						if listWidthAtDragStart == nil { listWidthAtDragStart = listWidth }
						listWidth = min(520, max(280, (listWidthAtDragStart ?? listWidth) + Double(translation)))
					} onEnded: { listWidthAtDragStart = nil }
					ReaderView()
						.frame(minWidth: Self.readerMin, maxWidth: .infinity)
				}
			}
		}
		.environment(\.colorScheme, columnScheme ?? colorScheme)
		.background(AppTheme.background)
		// One loader bar along the top of the card: syncing, or a message body loading.
		.overlay(alignment: .top) {
			LoaderBar(isActive: store.isSyncing || store.isSearchingServer || store.isFetchingUnread || (store.selectedID != nil && store.detail == nil))
		}
		.clipShape(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous).stroke(AppTheme.outline, lineWidth: 1))
	}

	// MARK: Titlebar

	/// macOS has notifications off for Mailflare.
	private var blockedBySystem: Bool { store.notifier.authorization == .denied }

	private var titlebarLeading: some View {
		// With the sidebar docked the toggle ends where the account dropdown does, and the
		// notification warning sits to its left. Otherwise the toggle starts past the traffic lights.
		let docked = sidebarDocked
		let toggle = TitlebarIconButton(icon: .sidebar, help: "Toggle sidebar (⌃⌘S)") { toggleSidebar() }
			.keyboardShortcut("s", modifiers: [.control, .command])
		let warning = TitlebarIconButton(icon: .notificationOff, help: "Notification is off", tint: .orange) {
			// macOS blocks it: only System Settings can lift that. Otherwise it is Mailflare's own switch.
			if blockedBySystem { MailNotifier.openSystemSettings() } else { store.settingsPage = .notifications }
		}
		let warns = blockedBySystem || !notificationsOn
		// Each button has a place of its own, so docking and undocking moves them instead of rebuilding them.
		let size = TitlebarIconButton.size, step = TitlebarIconButton.size + 3.5
		let toggleX = docked ? max(0, dockedSidebarW - SidebarView.gutter - size) : WindowChromeMetrics.sidebarToggleLeading
		let warningX = docked ? toggleX - step : toggleX + step
		let backX = toggleX + step + (warns && !docked ? step : 0)
		return ZStack(alignment: .topLeading) {
			if warns { warning.offset(x: warningX) }
			toggle.offset(x: toggleX)
			// Narrow windows show one column at a time; this goes from the message back to the list.
			if layout.single && !narrowChat && store.selectedID != nil && store.settingsPage == nil {
				TitlebarIconButton(icon: .arrowLeft, help: "Back to messages") { store.select(nil) }
					.offset(x: backX)
			}
		}
		.animation(.easeInOut(duration: 0.2), value: docked)
		.padding(.top, WindowChromeMetrics.titlebarRowCenter - TitlebarIconButton.size / 2)
	}

	/// The search field, always shown over the message list and aligned with its leading edge.
	/// With the sidebar hidden it starts past the sidebar toggle instead.
	private var titlebarSearch: some View {
		@Bindable var store = store
		let leading = searchLeading
		let backShown = narrowChat && store.selectedID != nil
		// One column: the field runs to the window's edge, less the assistant button; beside the
		// assistant, to the column's edge. With a message open it leaves room for the back button
		// and for the message's actions.
		let listEnd = layout.showList ? (layout.showSidebar ? layout.sidebarW : 0) + layout.listW
			: (narrowChat ? narrowColumnEnd : windowWidth - 56)
		let width = backShown ? Self.narrowSearchWidth : max(120, listEnd - leading)
		let field = HStack(spacing: 6) {
			HIcon(.search, size: 14).foregroundStyle(.secondary)
			TextField("Search", text: $store.searchText)
				.textFieldStyle(.plain).font(Typography.body)
				.focused($searchFocused)
				.onExitCommand { store.searchText = ""; searchFocused = false }
			if !store.searchText.isEmpty {
				Button { store.searchText = "" } label: { HIcon(.close, size: 12) }
					.buttonStyle(.light).foregroundStyle(.secondary)
			}
		}
		.padding(.horizontal, 10)
		.frame(width: width, height: 28)
		.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
		.contentShape(Rectangle())
		.onTapGesture { searchFocused = true }
		// ⌥⌘F focuses the field.
		.background { Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: [.command, .option]).opacity(0).frame(width: 0, height: 0) }
		return HStack(spacing: 6) {
			field
			if backShown {
				TitlebarIconButton(icon: .arrowLeft, help: "Back to messages") { store.select(nil) }
			}
		}
		.padding(.leading, leading)
		.padding(.top, WindowChromeMetrics.titlebarRowCenter - 14)
	}

	/// Where the search field starts: the list's leading edge, or past the sidebar toggle.
	private var searchLeading: CGFloat {
		let listLeading = layout.showSidebar ? layout.sidebarW : 0
		return max(listLeading, WindowChromeMetrics.sidebarToggleLeading + TitlebarIconButton.size + 8)
	}

	/// With the assistant docked beside one column: where that column ends.
	private var narrowColumnEnd: CGFloat { windowWidth - AIChatPanel.width - WindowChromeMetrics.cardInset * 2 }

	/// The search field's width while a message is open beside the assistant.
	private static let narrowSearchWidth: CGFloat = 170

	/// Message actions in the order they leave the header as it narrows (first to go, first listed
	/// in `hideOrder`); the ones that go move into the More menu. Flag and More always stay.
	private enum HeaderAction: CaseIterable {
		case reply, replyAll, forward, archive, trash, junk, summarize, colors
		static let hideOrder: [HeaderAction] = [.colors, .summarize, .junk, .forward, .replyAll, .archive, .trash, .reply]
	}

	/// The header actions that apply to this message.
	private func applicableActions(_ message: MessageSummary, role: String?) -> Set<HeaderAction> {
		var set: Set<HeaderAction> = [.trash]
		guard role != "drafts" else { return set }
		set.formUnion([.reply, .forward])
		if store.canReplyAll { set.insert(.replyAll) }
		if role != "archive" { set.insert(.archive) }
		if role != "junk" && role != "sent" { set.insert(.junk) }
		if store.ai.isConfigured { set.insert(.summarize) }
		// Only where the body has no dark styles of its own to defer to.
		if colorScheme == .dark, columnScheme == nil, let html = store.detail.flatMap({ $0.summary.id == message.id ? $0.html : nil }),
		   !MessageAppearance.supportsDark(html) {
			set.insert(.colors)
		}
		return set
	}

	/// The width of the header's reader section: from the reader's leading edge (which lines up with
	/// the message content) to where the actions end.
	private var headerActionsSpace: CGFloat {
		guard windowWidth > 0 else { return .infinity }
		// Beside the assistant the actions fill what is left of the column after the back button.
		if narrowChat {
			let start = searchLeading + Self.narrowSearchWidth + 6 + TitlebarIconButton.size + 8
			return max(0, narrowColumnEnd - 8 - start)
		}
		let readerLeft = layout.single ? 130 : (layout.showSidebar ? layout.sidebarW : 0) + layout.listW + WindowChromeMetrics.cardInset
		return windowWidth - readerLeft - (WindowChromeMetrics.cardInset + 8 + toggleInset) - 20
	}

	/// How wide the header row is with `shown` actions: buttons, separators and the 8pt gaps.
	private func headerActionsWidth(_ shown: Set<HeaderAction>, isDraft: Bool) -> CGFloat {
		func count(_ actions: [HeaderAction]) -> Int { actions.filter(shown.contains).count }
		let first = count([.reply, .replyAll, .forward]), second = count([.archive, .trash, .junk])
		let buttons = first + second + count([.summarize, .colors]) + (isDraft ? 0 : 2)
		let separators = 1 + (first > 0 ? 1 : 0) + (second > 0 && !isDraft ? 1 : 0)
		let items = buttons + separators
		return CGFloat(buttons) * TitlebarIconButton.size + CGFloat(separators) * 17 + CGFloat(max(items - 1, 0)) * 8
	}

	private func perform(_ action: HeaderAction, on message: MessageSummary) {
		switch action {
		case .reply: store.reply(to: message.id, all: false)
		case .replyAll: store.reply(to: message.id, all: true)
		case .forward: store.forward(message.id)
		case .archive: store.archive(message.id)
		case .trash: store.trash(message.id)
		case .junk: store.junk(message.id)
		case .summarize: store.summarizeSelected()
		case .colors: store.toggleAdaptColors()
		}
	}

	/// Keeps a hidden action's keyboard shortcut working.
	@ViewBuilder
	private func hiddenShortcut(_ action: HeaderAction, message: MessageSummary) -> some View {
		let button = Button("") { perform(action, on: message) }
		switch action {
		case .reply: button.keyboardShortcut("r")
		case .replyAll: button.keyboardShortcut("r", modifiers: [.command, .shift])
		case .forward: button.keyboardShortcut("f", modifiers: [.command, .shift])
		case .archive: button.keyboardShortcut("a", modifiers: [.command, .control])
		case .trash: button.keyboardShortcut(.delete, modifiers: .command)
		case .junk: button.keyboardShortcut("j", modifiers: [.command, .shift])
		case .summarize, .colors: EmptyView()
		}
	}

	/// The actions that apply to the selected message, on the card's trailing edge, grouped by
	/// separators. Nothing shows without a selection. As the reader narrows they leave one at a time
	/// into the More menu, and come back as it widens.
	private var titlebarTrailing: some View {
		let message = store.multiSelection.isEmpty ? store.selectedMessage : nil
		let role = message.map { store.role(of: $0) } ?? nil
		let isDraft = role == "drafts"
		var shown = message.map { applicableActions($0, role: role) } ?? []
		let applicable = shown
		for action in HeaderAction.hideOrder where headerActionsWidth(shown, isDraft: isDraft) > headerActionsSpace {
			shown.remove(action)
		}
		let hidden = HeaderAction.allCases.filter { applicable.contains($0) && !shown.contains($0) }
		return HStack(spacing: 8) {
			if let message {
				if !isDraft {
					if shown.contains(.reply) {
						TitlebarIconButton(icon: .reply, help: "Reply (⌘R)") { store.reply(to: message.id, all: false) }
							.keyboardShortcut("r")
					}
					if shown.contains(.replyAll) {
						TitlebarIconButton(icon: .replyAll, help: "Reply All (⇧⌘R)") { store.reply(to: message.id, all: true) }
							.keyboardShortcut("r", modifiers: [.command, .shift])
					}
					if shown.contains(.forward) {
						TitlebarIconButton(icon: .forward, help: "Forward (⇧⌘F)") { store.forward(message.id) }
							.keyboardShortcut("f", modifiers: [.command, .shift])
					}
					if shown.contains(.reply) || shown.contains(.replyAll) || shown.contains(.forward) { separator }
				}
				if shown.contains(.archive) {
					TitlebarIconButton(icon: .archive, help: "Archive (⌃⌘A)") { store.archive(message.id) }
						.keyboardShortcut("a", modifiers: [.command, .control])
				}
				if shown.contains(.trash) {
					TitlebarIconButton(icon: .trash, help: "Move to Trash (⌘⌫)") { store.trash(message.id) }
						.keyboardShortcut(.delete, modifiers: .command)
				}
				if shown.contains(.junk) {
					TitlebarIconButton(icon: .junk, help: "Move to Junk (⇧⌘J)") { store.junk(message.id) }
						.keyboardShortcut("j", modifiers: [.command, .shift])
				}
				if !isDraft {
					if shown.contains(.archive) || shown.contains(.trash) || shown.contains(.junk) { separator }
					if shown.contains(.summarize) {
						TitlebarIconButton(icon: .aiContent, help: store.summarizingID == message.id ? "Summarizing…" : "Summarize with AI",
										   isEnabled: store.detail?.summary.id == message.id, isLoading: store.summarizingID == message.id) { store.summarizeSelected() }
					}
					if shown.contains(.colors) {
						TitlebarIconButton(
							icon: .colors,
							help: store.adaptColors ? "Show Original Colors" : "Adapt Colors to Dark Mode",
							isActive: !store.adaptColors
						) { store.toggleAdaptColors() }
					}
					flagMenu(message)
					moreMenu(message, role: role, hidden: hidden)
				}
				separator
			}
		}
		.background {
			if let message { ForEach(hidden, id: \.self) { hiddenShortcut($0, message: message) }.opacity(0).frame(width: 0, height: 0) }
		}
		.animation(.snappy(duration: 0.2), value: hidden)
		.padding(.trailing, narrowChat ? AIChatPanel.width + WindowChromeMetrics.cardInset * 2 + 8 : WindowChromeMetrics.cardInset + 8 + toggleInset)
		.padding(.top, WindowChromeMetrics.titlebarRowCenter - TitlebarIconButton.size / 2)
	}

	/// The assistant button sits at the far right of the title bar; the message actions end before it.
	private var toggleInset: CGFloat { store.ai.isConfigured ? TitlebarIconButton.size + 6 : 0 }

	/// The sparkles button at the far right of the header; it opens and closes the assistant.
	private var assistantToggle: some View {
		TitlebarIconButton(icon: .sparkles, help: store.chatOpen ? "Close Assistant" : "Assistant", isActive: store.chatOpen, tooltipTrailing: true) {
			withAnimation(.easeInOut(duration: 0.2)) { store.chatOpen.toggle() }
		}
		.padding(.trailing, WindowChromeMetrics.cardInset + 8)
		.padding(.top, WindowChromeMetrics.titlebarRowCenter - TitlebarIconButton.size / 2)
	}

	private var separator: some View {
		Rectangle().fill(AppTheme.cardStroke).frame(width: 1, height: 16).padding(.horizontal, 8)
	}

	/// The "…" button and its dropdown: the Settings dropdown's card, opening below the button with
	/// its right edge on the button's.
	private func moreMenu(_ message: MessageSummary, role: String?, hidden: [HeaderAction]) -> some View {
		let unsubscribe = store.detail.flatMap { $0.summary.id == message.id ? UnsubscribeLink.find(in: $0.html) : nil }
		func choose(_ action: () -> Void) {
			withAnimation(.snappy(duration: 0.2)) { moreOpen = false }
			action()
		}
		return TitlebarIconButton(icon: .more, help: "More", isActive: moreOpen) {
			withAnimation(.snappy(duration: 0.2)) { moreOpen.toggle() }
		}
		.overlay(alignment: .topTrailing) {
			if moreOpen {
				DropdownCard(width: 210, anchor: .topTrailing) {
					// Header actions that no longer fit. Archive, Junk and Trash are already under "Move to".
					let moved = hidden.filter { ![.archive, .trash, .junk].contains($0) }
					ForEach(moved, id: \.self) { action in
						switch action {
						case .reply: DropdownRow(label: "Reply", icon: .reply) { choose { perform(action, on: message) } }
						case .replyAll: DropdownRow(label: "Reply All", icon: .replyAll) { choose { perform(action, on: message) } }
						case .forward: DropdownRow(label: "Forward", icon: .forward) { choose { perform(action, on: message) } }
						case .summarize:
							DropdownRow(label: "Summarize with AI", icon: .aiContent, isEnabled: store.detail?.summary.id == message.id && store.summarizingID != message.id) {
								choose { perform(action, on: message) }
							}
						case .colors:
							DropdownRow(label: store.adaptColors ? "Show Original Colors" : "Adapt Colors to Dark Mode", icon: .colors) {
								choose { perform(action, on: message) }
							}
						case .archive, .trash, .junk: EmptyView()
						}
					}
					if !moved.isEmpty { DropdownDivider() }
					DropdownRow(label: "Unsubscribe", icon: .unsubscribe, isEnabled: unsubscribe != nil) {
						choose { if let unsubscribe { NSWorkspace.shared.open(unsubscribe) } }
					}
					DropdownRow(label: "Block Contact", icon: .block) { choose { store.block(message.sender, messageID: message.id) } }
					DropdownRow(label: "Show Original", icon: .sourceCode) { choose { store.original = message } }
					DropdownDivider()
					DropdownLabel(title: "Move to")
					DropdownRow(label: "Archive", icon: .archive, isEnabled: role != "archive") { choose { store.archive(message.id) } }
					DropdownRow(label: "Spam", icon: .junk, isEnabled: role != "junk") { choose { store.junk(message.id) } }
					DropdownRow(label: "Trash", icon: .trash, isEnabled: role != "trash") { choose { store.trash(message.id) } }
				}
				.offset(y: TitlebarIconButton.size + 6)
			}
		}
		.clickAway(isActive: moreOpen) { withAnimation(.snappy(duration: 0.2)) { moreOpen = false } }
		.onChange(of: message.id) { _, _ in moreOpen = false }
	}

	private func flagMenu(_ message: MessageSummary?) -> some View {
		TitlebarMenu(icon: .flag, help: "Flag", isEnabled: message != nil, primaryAction: {
			if let message { store.toggleFlag(message.id) }
		}) {
			Button(message?.flagged == true ? "Remove Flag" : "Flag") { if let message { store.toggleFlag(message.id) } }
			Button(message?.seen == true ? "Mark as Unread" : "Mark as Read") {
				if let message { store.setRead(message.id, !message.seen) }
			}
			if store.supportsReminders {
				Divider()
				Button("Remind Me Tomorrow") {
					if let message { store.remind(message.id, at: Calendar.current.date(byAdding: .day, value: 1, to: .now)) }
				}
				if let message, store.reminders[message.id] != nil {
					Button("Clear Reminder") { store.remind(message.id, at: nil) }
				}
			}
			if store.supportsVIPs {
				Divider()
				Button(store.isVIP(message?.sender) ? "Remove Sender from VIPs" : "Add Sender to VIPs") {
					if let sender = message?.sender { store.toggleVIP(sender) }
				}
				.disabled(message == nil)
			}
		}
	}
}
