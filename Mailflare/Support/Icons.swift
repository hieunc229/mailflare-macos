import SwiftUI

/// Every glyph in the app comes from Hugeicons (free set, MIT), vendored as template PDFs in
/// `Assets.xcassets/Icons` so the app ships only the icons it uses rather than the whole library.
/// To add one, copy its `.imageset` from the free set into that folder and map it here.
enum AppIcon: String {
	case sidebar, filter, compose, reply, replyAll, forward, archive, trash, junk, folder, flag
	case moreDown, search, allInboxes, vip, remind, drafts, sent, smartMailbox, inbox
	case attachment, summarize, aiContent, chevronRight, chevronDown, clock, close, send, add, addCircle, check, signOut, appearance, settings, info, more, bell
	case crown, arrowLeft, sparkles, edit, colors, download, copy, label, unsubscribe, block, sourceCode, cancel, minimize, bold, italic, underline, strikethrough, bulletList, numberList, quote, link, clearFormat, undo, redo, support, markRead, markUnread, unflag
	case notificationOff, calendar, cart, money, person, work, travel, home, bookmark, parcel, refresh, expand, shrink

	/// The image in `Assets.xcassets/Icons`.
	var assetName: String { "Icons/" + fileName }

	private var fileName: String {
		switch self {
		case .sidebar: "sidebar-left"
		case .filter: "filter-mail"
		case .compose: "edit02"
		case .reply: "link-backward"
		case .replyAll: "mail-reply-all01"
		case .forward: "link-forward"
		case .archive: "archive02"
		case .trash: "delete02"
		case .junk: "spam"
		case .folder: "folder01"
		case .flag: "flag01"
		case .moreDown: "arrow-down01"
		case .search: "search01"
		case .allInboxes: "mailbox01"
		case .vip: "star"
		case .remind: "clock01"
		case .drafts: "file02"
		case .sent: "sent"
		case .smartMailbox: "haze"
		case .inbox: "inbox"
		case .attachment: "attachment01"
		case .summarize: "sparkles"
		case .aiContent: "ai-content-generator01"
		case .chevronRight: "arrow-right01"
		case .chevronDown: "arrow-down01"
		case .clock: "alarm-clock"
		case .close: "cancel01"
		case .send: "mail-send01"
		case .add: "add01"
		case .addCircle: "add-circle"
		case .check: "tick02"
		case .signOut: "logout01"
		case .appearance: "sun03"
		case .settings: "settings02"
		case .info: "information-circle"
		case .more: "more-horizontal"
		case .bell: "notification01"
		case .label: "tag01"
		case .unsubscribe: "mail-remove01"
		case .block: "user-block01"
		case .sourceCode: "source-code"
		case .cancel: "cancel01"
		case .minimize: "minus-sign"
		case .bold: "text-bold"
		case .italic: "text-italic"
		case .underline: "text-underline"
		case .strikethrough: "text-strikethrough"
		case .bulletList: "left-to-right-list-bullet"
		case .numberList: "left-to-right-list-number"
		case .arrowLeft: "arrow-left02"
		case .edit: "edit02"
		case .download: "download01"
		case .copy: "copy01"
		case .colors: "colors"
		case .sparkles: "sparkles"
		case .crown: "crown"
		case .quote: "quote-down"
		case .link: "link01"
		case .clearFormat: "text-clear"
		case .undo: "undo03"
		case .redo: "redo03"
		case .support: "customer-support"
		case .markRead: "mail-open01"
		case .markUnread: "mail01"
		case .unflag: "flag02"
		case .notificationOff: "notification-block01"
		case .calendar: "calendar01"
		case .cart: "shopping-cart01"
		case .money: "dollar-circle"
		case .person: "user"
		case .work: "briefcase01"
		case .travel: "airplane01"
		case .home: "home01"
		case .bookmark: "bookmark01"
		case .parcel: "package"
		case .refresh: "refresh01"
		case .expand: "arrow-expand"
		case .shrink: "arrow-shrink"
		}
	}
}

struct HIcon: View {
	let icon: AppIcon
	var size: CGFloat = 16

	init(_ icon: AppIcon, size: CGFloat = 16) {
		self.icon = icon
		self.size = size
	}

	var body: some View {
		Image(icon.assetName)
			.resizable()
			.renderingMode(.template)
			.scaledToFit()
			.frame(width: size, height: size)
	}
}
