import SwiftUI
import MailflareCore

struct MessageListView: View {
	@Environment(MailStore.self) private var store
	@State private var isHoveringFilter = false

	var body: some View {
		VStack(spacing: 0) {
			header
				// Above the list, so the filter button's tooltip is not covered by it.
				.zIndex(1)
			Rectangle().fill(AppTheme.cardStroke).frame(height: 1)
			list
		}
		.background(AppTheme.background)
	}

	/// The mailbox in view and how many messages it holds, on one row, with the unread filter.
	private var header: some View {
		HStack(alignment: .center, spacing: 8) {
			// One run of text, so the title and the count share a baseline and the pair is centred.
			(Text(store.title).font(.system(size: 15, weight: .semibold))
				+ Text("   ")
				+ Text(store.subtitle).font(Typography.meta).foregroundStyle(.secondary))
				.lineLimit(1)
			Spacer(minLength: 4)
			Button { store.unreadOnly.toggle() } label: {
				HIcon(.filter, size: 15)
					.frame(width: 26, height: 26)
					.foregroundStyle(store.unreadOnly ? Color.accentColor : Color.secondary)
					.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(store.unreadOnly ? AppTheme.railSelection : .clear))
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.onHover { isHoveringFilter = $0 }
			.titlebarTooltip(store.unreadOnly ? "Showing unread only" : "Filter unread messages", isHovering: isHoveringFilter)
			.accessibilityLabel(store.unreadOnly ? "Showing unread only" : "Filter unread messages")
		}
		.padding(.horizontal, 16)
		.frame(height: PaneHeader.height)
	}

	/// A row is at most this tall (sender, subject, two preview lines). A row with a shorter preview is
	/// shorter, but its height still follows from the message alone (see `RowMetrics`), so which rows
	/// are on screen follows from the scroll offset without laying any of them out.
	static let rowHeight: CGFloat = 92
	/// The space above the first row and below the last.
	static let listInset: CGFloat = 4
	@State private var metrics = RowMetrics()
	/// Read so the list lays out again when the setting changes (row insets and heights follow it).
	@AppStorage(ReadingSettings.showAvatarsKey) private var showAvatars = true
	@State private var listWidth: CGFloat = 360
	/// Rows are kept for the visible page plus this many pages above and below it.
	private static let bufferPages = 2

	@State private var firstVisibleRow = 0
	@State private var viewportHeight: CGFloat = 600
	/// The row a right click opened the menu on, and where in the list the click was.
	@State private var menu: ContextMenuTarget?
	/// The scroll offset, kept off `@State` so scrolling does not redraw the list for it.
	@State private var scrollPosition = ScrollPosition()

	private struct ContextMenuTarget: Equatable {
		var id: String
		var point: CGPoint
	}

	private final class ScrollPosition { var offset: CGFloat = 0 }

	/// One point under the body text.
	private static let menuFont = Font.system(size: Typography.baseSize - 1)
	private static let menuWidth: CGFloat = 168
	/// The menu's size before it is measured. Every menu has the same rows, so one measure serves all.
	private static let menuHeight: CGFloat = 200
	@State private var menuSize: CGSize?

	/// Only the rows near the viewport exist as views; the rest are replaced by spacers of the same
	/// height, so scrolling a long mailbox never builds (or keeps) thousands of rows.
	private var list: some View {
		ScrollViewReader { proxy in
			ScrollView {
				rows
			}
			.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
			.focusable()
			.focusEffectDisabled()
			.onMoveCommand { direction in
				guard let i = store.messages.firstIndex(where: { $0.id == store.selectedID }) else {
					if let first = store.messages.first { store.select(first.id) }
					return
				}
				let next = direction == .down ? i + 1 : (direction == .up ? i - 1 : i)
				guard store.messages.indices.contains(next) else { return }
				store.select(store.messages[next].id)
				proxy.scrollTo(store.messages[next].id)
			}
			.onExitCommand { closeMenu() }
		}
		.overlay { menuLayer }
		// Last, so it sees right clicks before anything below; it lets every other event through.
		.overlay { RightClickCatcher { openMenu(at: $0) } }
		.onChange(of: store.messages) { _, _ in resync(); loadMoreIfNearEnd() }
		.onChange(of: listWidth) { _, _ in resync() }
		// Older mail stored by the server fetch, which may not change the rows listed yet.
		.onChange(of: store.total) { _, _ in loadMoreIfNearEnd() }
		.overlay {
			if store.isAwaitingMail {
				MessageListSkeleton()
			} else if store.messages.isEmpty, store.loadMoreFailed {
				VStack(spacing: 10) {
					EmptyStateView(icon: .inbox, title: "Couldn’t Load Messages", message: "The server couldn’t be reached.")
						.fixedSize(horizontal: false, vertical: true)
					Button("Retry") { store.retryLoadMore() }.buttonStyle(.pill)
				}
			} else if store.messages.isEmpty {
				if store.searchText.isEmpty {
					EmptyStateView(icon: .inbox, title: "No Messages")
				} else {
					EmptyStateView(icon: .search, title: "No Results", message: "Nothing matches “\(store.searchText)”.")
				}
			}
		}
	}

	/// Called by the scroll observer whenever the list scrolls or is resized; moves the window of
	/// built rows so a row is a real view by the time it scrolls into sight.
	private func scrolled(offset: CGFloat, viewport: CGFloat) {
		if menu != nil, abs(offset - scrollPosition.offset) > 0.5 { menu = nil }
		scrollPosition.offset = offset
		let row = metrics.row(at: offset)
		if row != firstVisibleRow { firstVisibleRow = row }
		if abs(viewport - viewportHeight) > 1 { viewportHeight = viewport }
		loadMoreIfNearEnd()
	}

	/// After the messages or their heights change: the row at the scroll offset, redrawn if it moved.
	private func resync() {
		let row = metrics.row(at: scrollPosition.offset)
		if row != firstVisibleRow { firstVisibleRow = row }
	}

	/// Tells the store where the reader is, after a scroll and after the list changes (a short list
	/// that does not fill the pane never scrolls); it decides what to load ahead.
	private func loadMoreIfNearEnd() {
		guard store.canLoadMore else { return }
		let count = store.messages.count
		let lastVisible = count == 0 ? -1 : metrics.row(at: scrollPosition.offset + viewportHeight)
		store.loadMore(rowsBelow: count - 1 - lastVisible, screenRows: Int((viewportHeight / Self.rowHeight).rounded(.up)))
	}

	/// Below the last row: a spinner while older mail comes in, or a way to try again after it failed.
	@ViewBuilder
	private var footer: some View {
		if store.isLoadingMore {
			ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 44)
		} else if store.loadMoreFailed {
			HStack(spacing: 8) {
				Text("Couldn’t load older messages.").font(Typography.meta).foregroundStyle(.secondary)
				Button("Retry") { store.retryLoadMore() }.buttonStyle(.link).font(Typography.meta)
			}
			.frame(maxWidth: .infinity).frame(height: 44)
		}
	}

	private var rows: some View {
		let messages = store.messages
		let count = messages.count
		metrics.update(messages: messages, width: listWidth, isDraft: { store.role(of: $0) == "drafts" })
		let pageRows = max(1, Int((viewportHeight / Self.rowHeight).rounded(.up)))
		// Worked out from the real scroll offset against these messages' heights. `firstVisibleRow` is only
		// what makes the list redraw when that changes: after a switch to another folder the old row
		// number maps to a different place (rows differ in height), which left the viewport on spacers.
		_ = firstVisibleRow
		let first = min(metrics.row(at: scrollPosition.offset), max(count - 1, 0))
		let start = max(0, first - Self.bufferPages * pageRows)
		let end = min(count, first + (Self.bufferPages + 1) * pageRows)
		return VStack(spacing: 0) {
			Color.clear.frame(height: metrics.offset(of: start))
			if start < end {
				ForEach(Array(messages[start..<end].enumerated()), id: \.element.id) { offset, message in
					let index = start + offset
					let nextIsSelected = messages.indices.contains(index + 1) && (store.multiSelection.isEmpty ? messages[index + 1].id == store.selectedID : store.multiSelection.contains(messages[index + 1].id))
					let selected = store.multiSelection.isEmpty ? message.id == store.selectedID : store.multiSelection.contains(message.id)
					MessageRow(
						message: message, isDraft: store.role(of: message) == "drafts", isSelected: selected,
						isMenuTarget: menu?.id == message.id,
						sourceAccount: store.activeViewID == nil ? nil : store.accountID(of: message),
						showsDivider: index < count - 1 && !selected && !nextIsSelected,
						height: metrics.height(at: index))
						.id(message.id)
						.onTapGesture {
							let flags = NSEvent.modifierFlags
							if flags.contains(.shift) { store.extendSelection(to: message.id) }
							else if flags.contains(.command) { store.toggleSelection(of: message.id) }
							else { store.select(message.id) }
						}
				}
			}
			Color.clear.frame(height: max(metrics.offset(of: count) - metrics.offset(of: end), 0))
			if count > 0 { footer }
		}
		.background(ScrollObserver { offset, viewport in scrolled(offset: offset, viewport: viewport) })
		.padding(.vertical, Self.listInset)
	}

	// MARK: Right-click menu

	/// Opens the menu on the row under a right click, at the click. A click below the last row does nothing.
	private func openMenu(at point: CGPoint) {
		let y = scrollPosition.offset + point.y - Self.listInset
		guard y >= 0, y < metrics.offset(of: store.messages.count) else { closeMenu(); return }
		let message = store.messages[metrics.row(at: y)]
		// A right click outside the picked rows leaves the multiple selection.
		if !store.multiSelection.isEmpty, !store.multiSelection.contains(message.id) { store.select(message.id) }
		withAnimation(.snappy(duration: 0.2)) { menu = ContextMenuTarget(id: message.id, point: point) }
	}

	private func closeMenu() {
		guard menu != nil else { return }
		withAnimation(.snappy(duration: 0.2)) { menu = nil }
	}

	/// The menu over the list: a click anywhere else closes it. The card opens at the click, flips to
	/// the other side of it when it would run past an edge, and is kept inside the list, which clips
	/// whatever sticks out of it.
	private var menuLayer: some View {
		GeometryReader { geo in
			if let target = menu, let message = store.messages.first(where: { $0.id == target.id }) {
				let size = menuSize ?? CGSize(width: Self.menuWidth, height: Self.menuHeight)
				let margin: CGFloat = 8
				let flipX = target.point.x + size.width > geo.size.width - margin
				let flipY = target.point.y + size.height > geo.size.height - margin
				let x = min(max(flipX ? target.point.x - size.width : target.point.x, margin), max(geo.size.width - size.width - margin, margin))
				let y = min(max(flipY ? target.point.y - size.height : target.point.y, margin), max(geo.size.height - size.height - margin, margin))
				ZStack(alignment: .topLeading) {
					Color.clear.contentShape(Rectangle()).onTapGesture { closeMenu() }
					menuCard(for: message, anchor: UnitPoint(x: flipX ? 1 : 0, y: flipY ? 1 : 0))
						.fixedSize()
						.onGeometryChange(for: CGSize.self) { $0.size } action: { menuSize = $0 }
						.offset(x: x, y: y)
						// Hidden for the one pass before its size is known, so it never shows out of place.
						.opacity(menuSize == nil ? 0 : 1)
				}
			}
		}
	}

	/// The "…" menu's card and rows, with the actions of a message.
	private func menuCard(for m: MessageSummary, anchor: UnitPoint) -> some View {
		let role = store.role(of: m)
		let ids = store.actionIDs(for: m.id)
		let many = ids.count > 1
		let picked = ids.compactMap { id in store.messages.first { $0.id == id } }
		func choose(_ action: () -> Void) {
			closeMenu()
			action()
		}
		let font = Self.menuFont
		return DropdownCard(width: Self.menuWidth, anchor: anchor, spacing: 1) {
			DropdownRow(label: "Reply", icon: .reply, isEnabled: !many, labelFont: font, verticalPadding: 3.5) { choose { store.reply(to: m.id, all: false) } }
			DropdownRow(label: "Forward", icon: .forward, isEnabled: !many, labelFont: font, verticalPadding: 3.5) { choose { store.forward(m.id) } }
			DropdownDivider()
			let allFlagged = picked.allSatisfy(\.flagged)
			let allRead = picked.allSatisfy(\.seen)
			DropdownRow(label: allFlagged ? "Remove Flag" : "Flag", icon: allFlagged ? .unflag : .flag, labelFont: font, verticalPadding: 3.5) { choose { store.toggleFlag(ids: ids) } }
			DropdownRow(label: allRead ? "Mark as Unread" : "Mark as Read", icon: allRead ? .markUnread : .markRead, labelFont: font, verticalPadding: 3.5) { choose { store.toggleRead(ids: ids) } }
			DropdownDivider()
			DropdownRow(label: "Archive", icon: .archive, isEnabled: role != "archive", labelFont: font, verticalPadding: 3.5) { choose { store.archive(ids: ids) } }
			DropdownRow(label: "Move to Junk", icon: .junk, isEnabled: role != "junk", labelFont: font, verticalPadding: 3.5) { choose { store.junk(ids: ids) } }
			DropdownRow(label: "Delete", icon: .trash, labelFont: font, verticalPadding: 3.5) { choose { store.trash(ids: ids) } }
		}
	}
}

/// Stands in for the list while the first page of mail is on its way: ten rows of grey bars.
struct MessageListSkeleton: View {
	/// Sender, subject and preview bar widths, varied so the rows do not look stamped.
	private static let widths: [(sender: CGFloat, subject: CGFloat, preview: CGFloat)] = [
		(110, 190, 0.9), (84, 150, 0.7), (130, 210, 0.95), (96, 170, 0.6), (120, 140, 0.85),
	]

	var body: some View {
		VStack(spacing: 0) {
			ForEach(0..<10, id: \.self) { index in
				let w = Self.widths[index % Self.widths.count]
				VStack(alignment: .leading, spacing: 8) {
					HStack {
						SkeletonBar(width: w.sender, height: 11)
						Spacer(minLength: 4)
						SkeletonBar(width: 34, height: 9)
					}
					SkeletonBar(width: w.subject, height: 10)
					GeometryReader { proxy in SkeletonBar(width: proxy.size.width * w.preview, height: 9) }.frame(height: 9)
				}
				.padding(.leading, MessageRow.textInset)
				.padding(.trailing, 16)
				.padding(.vertical, 14)
				.overlay(alignment: .bottom) {
					Rectangle().fill(AppTheme.cardStroke.opacity(0.7)).frame(height: 1).padding(.leading, MessageRow.textInset).padding(.trailing, 16)
				}
			}
			Spacer(minLength: 0)
		}
		.padding(.vertical, MessageListView.listInset)
		.background(AppTheme.background)
		.allowsHitTesting(false)
		.accessibilityLabel("Loading messages")
	}
}

/// Reports right clicks (and control-clicks) on the view it covers, as a point from that view's top-left
/// corner. It is only hit by those clicks; hovers, scrolls and ordinary clicks fall through to what is under it.
struct RightClickCatcher: NSViewRepresentable {
	var onRightClick: (CGPoint) -> Void

	func makeNSView(context: Context) -> CatcherView {
		let view = CatcherView()
		view.onRightClick = onRightClick
		return view
	}

	func updateNSView(_ view: CatcherView, context: Context) { view.onRightClick = onRightClick }

	final class CatcherView: NSView {
		var onRightClick: ((CGPoint) -> Void)?

		override var isFlipped: Bool { true }

		override func hitTest(_ point: NSPoint) -> NSView? {
			guard let event = NSApp.currentEvent else { return nil }
			let isRightClick = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
			return isRightClick ? super.hitTest(point) : nil
		}

		override func rightMouseDown(with event: NSEvent) { report(event) }

		override func mouseDown(with event: NSEvent) {
			if event.modifierFlags.contains(.control) { report(event) } else { super.mouseDown(with: event) }
		}

		private func report(_ event: NSEvent) { onRightClick?(convert(event.locationInWindow, from: nil)) }
	}
}

/// One message. Its text is inset `textInset` from the left, the unread dot sits in that margin,
/// and a hairline closes it off from the next row.
struct MessageRow: View {
	/// The avatar column starts as far from the left edge as the text ends from the right.
	static let avatarInset: CGFloat = 16
	static let avatarSize: CGFloat = 32
	static let avatarTop: CGFloat = 10
	/// Where a row's text starts: after the avatar column, or past the unread dot's margin without one.
	static var textInset: CGFloat { ReadingSettings.showAvatars ? avatarInset + avatarSize + 10 : 30 }
	/// The shortest a row can be: the avatar and its margins.
	static var minHeight: CGFloat { ReadingSettings.showAvatars ? avatarTop + avatarSize + 9 : 34 }

	@Environment(MailStore.self) private var store
	@AppStorage(ReadingSettings.showAvatarsKey) private var showAvatars = true

	let message: MessageSummary
	let isDraft: Bool
	let isSelected: Bool
	/// The row a right-click menu is open on, drawn as if hovered.
	var isMenuTarget = false
	/// In an inbox view, the account the message came from.
	var sourceAccount: String? = nil
	let showsDivider: Bool
	/// From `RowMetrics`: shorter than `MessageListView.rowHeight` when the preview is short or absent.
	var height: CGFloat = MessageListView.rowHeight

	@State private var isHovering = false

	/// The first line: the sender (or a draft's recipients).
	private var title: String {
		let name = isDraft ? message.toDisplay : (store.contacts.name(for: message.fromEmail) ?? message.senderDisplay)
		return name.trimmingCharacters(in: .whitespaces)
	}

	private var subject: String { message.subject.trimmingCharacters(in: .whitespaces) }
	private var preview: String { PreviewText.plain(message.preview) }

	/// "(No Subject)", dimmed and italic, where a subject should be.
	private var noSubject: some View {
		Text("(No Subject)").font(Typography.body.italic()).foregroundStyle(.tertiary).lineLimit(1)
	}

	/// Unread mail is bold and at full strength; read mail is lighter and a little dimmed.
	private var titleFont: Font { message.seen ? Typography.body.weight(.medium) : Typography.body.weight(.bold) }
	private var subjectFont: Font { message.seen ? Typography.body : Typography.body.weight(.semibold) }
	private var dim: Double { message.seen ? 0.68 : 1 }

	/// The blue dot for unread mail, on the row's last line of text and at the avatar's x (the left
	/// margin when avatars are off). `lineHeight` is that line's height, which it is centered on.
	@ViewBuilder
	private func unreadDot(isLast: Bool, lineHeight: CGFloat) -> some View {
		if isLast && !message.seen {
			let dotX = showAvatars ? MessageRow.avatarInset + (MessageRow.avatarSize - 7) / 2 : 15
			Circle().fill(Color.accentColor).frame(width: 7, height: 7)
				.offset(x: dotX - MessageRow.textInset, y: 3.5 - lineHeight / 2)
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				// With no sender, the subject (or its placeholder) takes the title's place.
				if title.isEmpty && !isDraft {
					if subject.isEmpty { noSubject } else { Text(subject).font(titleFont).opacity(dim).lineLimit(1) }
				} else {
					Text(title.isEmpty ? "Draft" : title).font(titleFont).opacity(dim).lineLimit(1)
				}
				Spacer(minLength: 4)
				if title.isEmpty && !isDraft {
					if message.hasAttachment { HIcon(.attachment, size: 13).foregroundStyle(.secondary) }
					if message.flagged { HIcon(.flag, size: 13).foregroundStyle(.orange) }
				}
				Text(MailDate.list(message.date))
					.font(Typography.meta).foregroundStyle(.secondary).lineLimit(1).fixedSize()
				// In a unified list, the inbox the message is in follows its date.
				if let sourceAccount {
					ProfileAvatar(key: AvatarCache.key(account: sourceAccount), name: store.accountList.first { $0.id == sourceAccount }.map(store.accountName) ?? "?", size: 15)
				}
			}
			.overlay(alignment: .bottomLeading) {
				unreadDot(isLast: preview.isEmpty && title.isEmpty && !isDraft, lineHeight: RowMetrics.bodyLine)
			}
			if !(title.isEmpty && !isDraft) {
				HStack(spacing: 4) {
					if subject.isEmpty { noSubject } else { Text(subject).font(subjectFont).opacity(dim).lineLimit(1) }
					Spacer(minLength: 4)
					if message.hasAttachment { HIcon(.attachment, size: 13).foregroundStyle(.secondary) }
					if message.flagged { HIcon(.flag, size: 13).foregroundStyle(.orange) }
				}
				.overlay(alignment: .bottomLeading) { unreadDot(isLast: preview.isEmpty, lineHeight: RowMetrics.bodyLine) }
			}
			if !preview.isEmpty {
				Text(preview).font(Typography.notice).foregroundStyle(.secondary).opacity(message.seen ? 0.8 : 1).lineLimit(2)
					.overlay(alignment: .bottomLeading) { unreadDot(isLast: true, lineHeight: RowMetrics.noticeLine) }
			}
		}
		.padding(.leading, MessageRow.textInset)
		.padding(.trailing, 16)
		.padding(.vertical, 9)
		.frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
		.background(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.fill(isSelected ? AppTheme.railSelection : (isHovering || isMenuTarget ? AppTheme.rowHighlight : .clear))
				.padding(.horizontal, 6)
		)
		.overlay(alignment: .topLeading) {
			if showAvatars {
				SenderAvatar(email: isDraft ? "" : message.fromEmail, name: title, size: MessageRow.avatarSize)
					.padding(.leading, MessageRow.avatarInset).padding(.top, MessageRow.avatarTop)
			}
		}
		.overlay(alignment: .bottom) {
			if showsDivider {
				Rectangle().fill(AppTheme.cardStroke.opacity(0.7)).frame(height: 1).padding(.leading, MessageRow.textInset).padding(.trailing, 16)
			}
		}
		.contentShape(Rectangle())
		.onHover { isHovering = $0 }
	}
}

/// A sender's picture: their Gravatar when they have one, otherwise their initial on a color
/// picked from a hash of the address (the same palette and hash as the web app).
struct SenderAvatar: View {
	@Environment(MailStore.self) private var store

	let email: String
	let name: String
	var size: CGFloat = 32

	private var identity: String {
		let address = email.trimmingCharacters(in: .whitespaces).lowercased()
		return address.isEmpty ? name.trimmingCharacters(in: .whitespaces).lowercased() : address
	}

	private var initial: String {
		let source = (store.contacts.name(for: email) ?? name).trimmingCharacters(in: .whitespaces)
		return String((source.isEmpty ? email : source).prefix(1)).uppercased()
	}

	var body: some View {
		Group {
			if let image = store.avatars.images[AvatarCache.contactKey(email)] {
				Image(nsImage: image).resizable().scaledToFill()
			} else {
				Text(initial.isEmpty ? "?" : initial)
					.font(.system(size: size * 0.42, weight: .semibold))
					.foregroundStyle(AvatarStyle.text)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(AvatarStyle.background(for: identity))
			}
		}
		.frame(width: size, height: size)
		.clipShape(Circle())
		.task(id: email) { store.avatars.loadContact(email: email) }
	}
}

/// Row heights, worked out from the messages instead of from laid-out views. A row is sender, subject
/// and up to two preview lines; a short preview takes one line, none takes none, and a message with
/// no sender drops the subject line. Line counts are measured once per message and width.
@MainActor
final class RowMetrics {
	private var heights: [CGFloat] = []
	private var offsets: [CGFloat] = [0]
	private var lines: [String: (preview: String, count: Int)] = [:]
	private var width: CGFloat = 0
	/// What the heights were last worked out for. The list's body asks on every scroll step, and the
	/// messages are usually the same array, which compares at once.
	private var measured: [MessageSummary] = []

	private static let noticeFont = NSFont.systemFont(ofSize: Typography.baseSize - 1)
	private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }
	static let noticeLine = lineHeight(noticeFont)
	static let bodyLine = lineHeight(NSFont.systemFont(ofSize: Typography.baseSize))

	func update(messages: [MessageSummary], width: CGFloat, isDraft: (MessageSummary) -> Bool) {
		// Preview text spans the row minus its insets.
		let textWidth = max(width - MessageRow.textInset - 16, 40)
		if abs(textWidth - self.width) > 0.5 { self.width = textWidth; lines.removeAll(keepingCapacity: true); measured = [] }
		else if heights.count == messages.count, messages == measured { return }
		measured = messages
		heights.removeAll(keepingCapacity: true)
		offsets.removeAll(keepingCapacity: true)
		heights.reserveCapacity(messages.count)
		offsets.reserveCapacity(messages.count + 1)
		var total: CGFloat = 0
		offsets.append(0)
		for message in messages {
			let h = height(for: message, isDraft: isDraft(message))
			heights.append(h)
			total += h
			offsets.append(total)
		}
	}

	func height(at index: Int) -> CGFloat { heights.indices.contains(index) ? heights[index] : MessageListView.rowHeight }

	/// Where row `index` starts (or, past the last row, the end of the list).
	func offset(of index: Int) -> CGFloat { offsets.isEmpty ? 0 : offsets[min(max(index, 0), offsets.count - 1)] }

	/// The row containing a scroll offset.
	func row(at y: CGFloat) -> Int {
		var low = 0, high = max(offsets.count - 2, 0)
		while low < high {
			let mid = (low + high + 1) / 2
			if offsets[mid] <= y { low = mid } else { high = mid - 1 }
		}
		return low
	}

	private func height(for message: MessageSummary, isDraft: Bool) -> CGFloat {
		let hasSender = !(isDraft ? message.toDisplay : message.senderDisplay).trimmingCharacters(in: .whitespaces).isEmpty
		let previewLines = previewLineCount(message)
		// Start from the full row (sender, subject, two preview lines) and take away what is missing.
		var h = MessageListView.rowHeight
		if !(hasSender || isDraft) { h -= 2 + Self.bodyLine }
		h -= CGFloat(2 - previewLines) * Self.noticeLine
		if previewLines == 0 { h -= 2 }
		return max(ceil(h), MessageRow.minHeight)
	}

	private func previewLineCount(_ message: MessageSummary) -> Int {
		let text = PreviewText.plain(message.preview)
		if text.isEmpty { return 0 }
		if let hit = lines[message.id], hit.preview == text { return hit.count }
		let box = (text as NSString).boundingRect(
			with: NSSize(width: width, height: .greatestFiniteMagnitude),
			options: .usesLineFragmentOrigin, attributes: [.font: Self.noticeFont])
		let count = box.height > Self.noticeLine * 1.5 ? 2 : 1
		lines[message.id] = (text, count)
		return count
	}
}
