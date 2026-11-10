import Foundation
import Observation
import AppKit
import SwiftUI
import MailflareCore

/// Hands core events back to the main actor.
private final class CoreEvents: CoreListener {
	nonisolated(unsafe) weak var store: MailStore?
	func onEvent(event: CoreEvent) {
		Task { @MainActor [weak store] in store?.handle(event) }
	}
}

@MainActor
@Observable
final class MailStore {
	enum Phase { case signedOut, connecting, ready }

	/// Starts as `.connecting` until `restore()` knows whether an account exists, so neither the
	/// main window nor the sign-in window flashes up first.
	var phase: Phase = .connecting
	var accountList: [Account] = []
	/// Set while the sign-in popup is up over the main window (adding another account).
	var showAddAccount = false
	/// The Settings page in view; nil shows the mailbox. Settings replace the list and reader.
	var settingsPage: SettingsPage?
	@ObservationIgnored private var markReadTask: Task<Void, Never>?
	let notifier = MailNotifier()
	/// Accounts with a background (quick) sync in flight: they refresh the list without the loader.
	@ObservationIgnored private var quietSyncs: Set<String> = []
	var banner: String?
	/// A short confirmation shown at the top right (sent, saved); it clears itself.
	var toast: Toast?
	@ObservationIgnored private var toastTask: Task<Void, Never>?
	var isSyncing = false
	/// Shown quietly in the sidebar when the server can't be reached; saved mail stays usable.
	var connectionNote: String?

	@ObservationIgnored private var core: MailCore?
	@ObservationIgnored private let events = CoreEvents()
	var account: Account?
	var mailboxes: [Mailbox] = []
	var identities: [Identity] = []
	var flaggedCount = 0
	var inboxUnread = 0
	/// The address mailbox the sidebar is scoped to; nil means all inboxes.
	var scopeID: String? = UserDefaults.standard.string(forKey: "scopeInbox")
	var brandName = "Mailflare"
	/// A licensed server's branding follows the app across accounts; otherwise the account's own.
	var displayBrandName: String { license.brandName ?? brandName }
	let license = LicenseManager()
	let ai = AISettings()
	let chat = AIChatModel()
	/// Whether the panel is showing: open, and a provider is set up to answer.
	var chatVisible: Bool { chatOpen && ai.isConfigured }
	/// Whether the assistant panel is open.
	var chatOpen = UserDefaults.standard.bool(forKey: "chatOpen") {
		didSet { UserDefaults.standard.set(chatOpen, forKey: "chatOpen") }
	}
	var mailCore: MailCore? { core }
	var currentAccountID: String { accountID }
	/// The raw id of the email in the reader, for the assistant's context.
	var openEmailIDForAI: String? { selectedID.map { owner(of: $0).message } }
	/// After the assistant changed mail: refresh what is on screen.
	func aiDidChangeMail() { invalidateCaches(); reload(); refreshMailboxes() }
	let profiles = AccountProfiles()
	/// Names and descriptions given to senders and recipients, kept on this Mac.
	let contacts = ContactProfiles()
	/// The rewrite prompts offered in the reply box: built in, and the user's own.
	let aiPrompts = AIPromptLibrary()
	@ObservationIgnored private(set) var avatars = AvatarCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("mailflare-avatars", isDirectory: true))

	var sidebar: SidebarItem = .allInboxes
	var messages: [MessageSummary] = []
	var total = 0
	var selectedID: String?
	/// Several messages picked at once with Shift or Command; empty when one message (or none) is.
	/// `selectedID` stays the anchor a Shift click extends from.
	var multiSelection: Set<String> = []
	var detail: MessageDetail?
	var searchText = ""
	/// Whether the open message's colors are re-made for the dark window (see `MessageAppearance`);
	/// the toolbar's colors button flips it for that sender.
	var adaptColors = true
	var unreadOnly = false
	var compose: ComposeDraft?

	/// Inbox views: named sets of inboxes, across accounts, listed together. Saved on this Mac.
	var inboxViews: [InboxView] = MailStore.loadInboxViews()
	/// Custom tabs, listed under Today. Saved on this Mac. Today itself is `CustomTab.today`, not stored.
	var customTabs: [CustomTab] = MailStore.loadCustomTabs()
	/// The tab open in the create/edit popup.
	var customTabEditor: CustomTab?
	@ObservationIgnored private var tabCounts: [String: Int] = [:]
	/// Goes up each time the local mail changes. The sidebar's counts read it, so every one of them is
	/// worked out again then, whatever else they happen to read: a count with the default scope reads
	/// nothing else that changes when a message is read.
	private(set) var mailRevision = 0
	/// The view whose inboxes are listed; nil lists the account in view as usual.
	var activeViewID: String?
	/// The view open in the create/edit popup.
	var inboxViewEditor: InboxView?
	/// The folder popup in view: a new folder, or a rename or delete of one.
	var folderRequest: FolderRequest?
	@ObservationIgnored private var folderSupportCache: [String: FolderSupport] = [:]
	var activeView: InboxView? {
		guard let id = activeViewID else { return nil }
		return id == Self.allAccountsID ? allAccountsView : inboxViews.first { $0.id == id }
	}

	/// A sidebar group's inbox kept apart from the dropdown's scope: the list narrows to it while the
	/// dropdown keeps showing what it chose.
	struct SidebarFocus: Equatable {
		var accountID: String
		var inboxID: String?
	}
	var focus: SidebarFocus?

	/// One entry of the sidebar's Accounts section: an account, or one inbox of an account with several.
	struct SidebarGroup: Identifiable {
		var id: String
		var title: String
		var help: String
		var avatarKey: String
		var account: Account
		var inbox: Mailbox?
		var focus: SidebarFocus { SidebarFocus(accountID: account.id, inboxID: inbox?.id) }
	}

	/// The groups of the inboxes in view, one level deep: "Account" or "Account / Inbox".
	var sidebarGroups: [SidebarGroup] {
		func groups(of account: Account, wanted: Set<String>?) -> [SidebarGroup] {
			let addresses = inboxAddresses(of: account.id)
			guard addresses.count > 1 else {
				return [SidebarGroup(id: account.id, title: accountName(account), help: account.email,
									 avatarKey: AvatarCache.key(account: account.id), account: account, inbox: nil)]
			}
			return addresses.filter { wanted?.contains($0.id) ?? true }.map { inbox in
				SidebarGroup(id: account.id + ":" + inbox.id, title: activeView == nil ? label(inbox) : "\(switcherName(account)) / \(label(inbox))", help: inbox.inboxEmail,
							 avatarKey: AvatarCache.key(account: account.id, mailbox: inbox.id), account: account, inbox: inbox)
			}
		}
		if let view = activeView {
			return view.accountIDs.compactMap { id in accountList.first { $0.id == id } }.flatMap { account -> [SidebarGroup] in
				let members = view.members.filter { $0.accountID == account.id }
				return groups(of: account, wanted: members.contains { $0.inboxID == nil } ? nil : Set(members.compactMap(\.inboxID)))
			}
		}
		return account.map { groups(of: $0, wanted: nil) } ?? []
	}

	/// The inbox a sidebar group narrows to inside the current account (no view in play).
	var focusInbox: Mailbox? {
		guard activeViewID == nil, let focus, focus.accountID == account?.id, let id = focus.inboxID else { return nil }
		return inboxAddresses.first { $0.id == id }
	}
	/// The chosen inbox, else the one a group narrowed to.
	var scopeInbox: Mailbox? { currentInbox ?? focusInbox }

	/// The view as it is loaded: narrowed to the focused group when there is one.
	var loadView: InboxView? {
		guard var view = activeView else { return nil }
		if let focus { view.members = [.init(accountID: focus.accountID, inboxID: focus.inboxID)] }
		return view
	}

	/// Opens `item` over everything in the dropdown's scope.
	func openTopItem(_ item: SidebarItem) {
		focus = nil
		settingsPage = nil
		go(to: item)
	}

	/// Opens `item` in one sidebar group, leaving the dropdown as it is.
	func openGroupItem(_ item: SidebarItem, in group: SidebarGroup) {
		focus = group.focus
		settingsPage = nil
		go(to: item)
	}

	private func go(to item: SidebarItem) {
		sidebar = item
		searchText = ""
		selectedID = nil; detail = nil
		pageLimit = pageSize
		// At once, so the old list never shows under the new title; `sidebarChanged` then reads the cache.
		reload()
	}

	/// Whether the single-inbox sidebar is in play: one inbox, not several combined.
	var isSingleScope: Bool { !showsAllInboxes }

	/// The folders and labels of the one inbox in view.
	var scopeFolders: [Mailbox] {
		if let inbox = currentInbox { return children(of: inbox).filter { $0.role == nil } }
		if inboxAddresses.isEmpty { return plainFolders }
		if inboxAddresses.count == 1 { return children(of: inboxAddresses[0]).filter { $0.role == nil } }
		return []
	}

	/// The unified scope: every inbox of every account, as a view that is never saved.
	static let allAccountsID = "all-accounts"
	var allAccountsView: InboxView {
		InboxView(id: Self.allAccountsID, name: "Unified Inbox", members: accountList.filter { unifiedIncludes($0.id) }.map { .init(accountID: $0.id, inboxID: nil) })
	}

	// MARK: Unified settings

	var unifiedExcluded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "unifiedExcludedAccounts") ?? [])

	var unifiedHidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "unifiedHiddenViews") ?? [])
	func unifiedShows(_ kind: UnifiedViewKind) -> Bool { !unifiedHidden.contains(kind.rawValue) }
	func setUnified(_ kind: UnifiedViewKind, shown: Bool) {
		if shown { unifiedHidden.remove(kind.rawValue) } else { unifiedHidden.insert(kind.rawValue) }
		UserDefaults.standard.set(Array(unifiedHidden), forKey: "unifiedHiddenViews")
	}

	/// The Organize setting a sidebar key belongs to; custom folders have none.
	static func viewKind(forKey key: String) -> UnifiedViewKind? {
		switch key {
		case "inbox": .inbox
		case "flagged": .starred
		case "drafts": .drafts
		case "sent": .sent
		case "junk": .spam
		case "trash": .trash
		case "archive": .archive
		default: nil
		}
	}

	/// Whether Organize lists the sidebar key at the top level; the rest live in the account's More.
	func isListed(_ key: String) -> Bool { Self.viewKind(forKey: key).map(unifiedShows) ?? true }

	func unifiedIncludes(_ accountID: String) -> Bool { !unifiedExcluded.contains(accountID) }
	var unifiedIncludedCount: Int { accountList.filter { unifiedIncludes($0.id) }.count }


	func setUnified(_ accountID: String, included: Bool) {
		if included { unifiedExcluded.remove(accountID) } else { unifiedExcluded.insert(accountID) }
		UserDefaults.standard.set(Array(unifiedExcluded), forKey: "unifiedExcludedAccounts")
		if isAllAccounts { pageLimit = pageSize; reload() }
	}
	var isAllAccounts: Bool { activeViewID == Self.allAccountsID }

	var vips: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "vips") ?? [])
	var reminders: [String: Date] = {
		(UserDefaults.standard.dictionary(forKey: "reminders") as? [String: Double])?.mapValues { Date(timeIntervalSince1970: $0) } ?? [:]
	}()

	@ObservationIgnored private var detailTask: Task<Void, Never>?
	@ObservationIgnored private var pollTask: Task<Void, Never>?
	/// Held while polling so App Nap does not stretch the poll interval of a hidden window.
	@ObservationIgnored private var pollActivity: NSObjectProtocol?
	@ObservationIgnored private var olderTask: Task<Void, Never>?
	@ObservationIgnored private var pageLimit = 50
	private let pageSize = 50
	/// Smart mailboxes and filters read a wider local window and filter it in memory.
	private let scanLimit: UInt32 = 1000

	init() {
		events.store = self
		notifier.open = { [weak self] account, message in self?.openMessage(accountID: account, messageID: message) }
		do {
			var base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
				.appendingPathComponent("Mailflare", isDirectory: true)
			#if DEBUG
			// Debug builds can point at a scratch directory so tests never touch a real account's cache.
			if let scratch = ProcessInfo.processInfo.environment["MAILFLARE_DATA_DIR"] { base = URL(fileURLWithPath: scratch, isDirectory: true) }
			#endif
			avatars = AvatarCache(directory: base.appendingPathComponent("avatars", isDirectory: true))
			quickReplies = QuickReplies(file: base.appendingPathComponent("quick-replies.json"))
			let core = try MailCore(dataDir: base.path, credentials: KeychainCredentialStore())
			core.setListener(listener: events)
			self.core = core
		} catch {
			banner = "Could not open the mail database (\(Self.dataDirectoryDescription)): \(describe(error))"
		}
	}

	private var accountID: String { account?.id ?? "" }

	static var dataDirectoryDescription: String {
		(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Mailflare").path ?? "Application Support/Mailflare")
			.replacingOccurrences(of: NSHomeDirectory(), with: "~")
	}

	// MARK: Sign-in

	func restore() async {
		guard phase == .connecting else { return }
		guard let core else { phase = .signedOut; return }
		#if DEBUG
		// Debug builds only: sign in from launch variables so screenshots need no typing.
		let env = ProcessInfo.processInfo.environment
		if let key = env["MAILFLARE_DEV_KEY"], let email = env["MAILFLARE_DEV_EMAIL"] {
			phase = .connecting
			do { activate(try await core.signIn(email: email, appPassword: key, serverUrl: env["MAILFLARE_DEV_SERVER"])) }
			catch { phase = .signedOut; banner = describe(error) }
			return
		}
		#endif
		if let first = try? core.accounts().first {
			if KeychainCredentialStore().load(accountId: first.id) == nil {
				// Cached mail stays on disk; signing in again replaces the key for the same account.
				endSession("Your saved sign-in could not be read from the Keychain. Sign in again.")
				return
			}
			activate(first)
			return
		}
		phase = .signedOut
	}

	/// Tries the account password first (device key + MFA), then falls back to an app password.
	func signIn(server: String, email: String, password: String, deviceName: String) async throws -> SignInOutcome {
		guard let core else { throw CoreError.Storage(message: "The mail database is not available.") }
		let url = server.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Self.normalize(server)
		do {
			switch try await core.signInWithPassword(email: email, password: password, serverUrl: url, deviceName: deviceName) {
			case .signedIn(let account):
				activate(account)
				return .signedIn
			case .mfaRequired(let challenge, let serverURL):
				return .needsCode(challenge: challenge, serverURL: serverURL)
			}
		} catch let error as CoreError {
			switch error {
			case .Network:
				// Say which address was tried: with no server given, the core guesses from the email's domain.
				if url == nil {
					let domain = email.split(separator: "@").last.map(String.init) ?? "your email's domain"
					throw CoreError.Network(message: "Could not reach a Mailflare server at \(domain). Enter your server address (for example mail.\(domain)).")
				}
				throw CoreError.Network(message: "Could not connect to \(server.trimmingCharacters(in: .whitespaces)). Check the address and your connection.")
			case .Auth, .Discovery:
				do {
					activate(try await core.signIn(email: email, appPassword: password, serverUrl: url))
					return .signedIn
				} catch let second as CoreError {
					if case .Auth = second { throw CoreError.Auth(message: "Invalid credentials. Use your account password or an app password.") }
					throw second
				}
			default: throw error
			}
		}
	}

	/// IMAP accounts: the core checks the login on the incoming and outgoing servers, then stores it.
	func signInIMAP(email: String, password: String, config: MailServerConfig) async throws {
		guard let core else { throw CoreError.Storage(message: "The mail database is not available.") }
		activate(try await core.signInImap(email: email.trimmingCharacters(in: .whitespaces), password: password, config: config))
	}

	/// Browser sign-in (OAuth2 + PKCE). Returns false when the person closed the sign-in window.
	@discardableResult
	func signInOAuth(email: String, client: OAuthClient, config: MailServerConfig) async throws -> Bool {
		guard let core else { throw CoreError.Storage(message: "The mail database is not available.") }
		let email = email.trimmingCharacters(in: .whitespaces)
		let authorization = try oauthAuthorization(client: client, email: email)
		guard let url = URL(string: authorization.url) else { return false }
		let callback: URL
		do {
			callback = try await WebAuthenticator().authenticate(url: url, redirectURI: client.redirectUri)
		} catch is WebAuthenticator.Cancelled {
			return false
		}
		activate(try await core.signInOauth(
			email: email, client: client, authorization: authorization, redirectUrl: callback.absoluteString, config: config))
		return true
	}

	func completeMFA(email: String, challenge: String, code: String, serverURL: String, deviceName: String) async throws {
		guard let core else { return }
		activate(try await core.completeMfa(email: email, challengeToken: challenge, code: code, serverUrl: serverURL, deviceName: deviceName))
	}

	// MARK: Folders and labels

	struct FolderRequest: Identifiable {
		enum Kind {
			case create(parentID: String?)
			case rename(Mailbox)
			case delete(Mailbox)
		}
		let id = UUID()
		var accountID: String
		var kind: Kind
	}

	/// What the account allows for folders (and whether to call them labels), nil when the core can't say.
	func folderSupport(accountID: String) -> FolderSupport? {
		if let cached = folderSupportCache[accountID] { return cached }
		guard let found = try? core?.folderSupport(accountId: accountID) else { return nil }
		folderSupportCache[accountID] = found
		return found
	}

	func canCreateFolders(accountID: String) -> Bool { folderSupport(accountID: accountID)?.canCreate ?? false }

	// Folder changes show in the sidebar at once and go to the server in the background (the core
	// waits for the server and a sync before it returns). Until then they are laid over the stored
	// mailboxes; a failure takes them back out and says why.

	/// Folders being created, by placeholder id, with the account they are in.
	@ObservationIgnored private var pendingFolders: [String: (account: String, box: Mailbox)] = [:]
	/// New names of folders being renamed, by `folderKey`.
	@ObservationIgnored private var pendingRenames: [String: String] = [:]
	/// Folders being deleted, by `folderKey`.
	@ObservationIgnored private var pendingDeletes: Set<String> = []

	private static let pendingPrefix = "pending:"
	private static func folderKey(_ accountID: String, _ id: String) -> String { accountID + "\n" + id }
	/// A folder shown before the server has it; it can't be renamed or deleted yet.
	static func isPending(_ box: Mailbox) -> Bool { box.id.hasPrefix(pendingPrefix) }

	/// The stored mailboxes of an account with the folder changes still on their way laid over them.
	private func overlayingFolderChanges(_ list: [Mailbox], accountID: String) -> [Mailbox] {
		guard !pendingFolders.isEmpty || !pendingRenames.isEmpty || !pendingDeletes.isEmpty else { return list }
		var result = list.compactMap { box -> Mailbox? in
			let key = Self.folderKey(accountID, box.id)
			if pendingDeletes.contains(key) { return nil }
			guard let name = pendingRenames[key] else { return box }
			var renamed = box
			// Nested folders can be named by their path; only the last part is renamed.
			var parts = box.name.components(separatedBy: " / ")
			parts[parts.count - 1] = name
			renamed.name = parts.joined(separator: " / ")
			return renamed
		}
		for (account, box) in pendingFolders.values where account == accountID {
			// The sync that ends the create can store the real folder a moment before the call returns.
			let arrived = result.contains { $0.parentId == box.parentId && $0.name.localizedCaseInsensitiveCompare(box.name) == .orderedSame }
			if !arrived { result.append(box) }
		}
		return result
	}

	private func folderFailed(_ verb: String, _ name: String, accountID: String, error: Error) {
		let noun = folderSupport(accountID: accountID)?.noun ?? "folder"
		banner = "Couldn’t \(verb) the \(noun) “\(name)”: \(describe(error))"
	}

	func createFolder(accountID: String, parentID: String?, name: String) {
		guard let core else { return }
		let name = name.trimmingCharacters(in: .whitespaces)
		let placeholder = Mailbox(id: Self.pendingPrefix + UUID().uuidString, accountId: accountID, name: name, parentId: parentID,
								  role: nil, sortOrder: .max, totalEmails: 0, unreadEmails: 0)
		pendingFolders[placeholder.id] = (accountID, placeholder)
		folderChanged(accountID: accountID)
		Task {
			do {
				try await core.createFolder(accountId: accountID, parentId: parentID, name: name)
			} catch {
				folderFailed("create", name, accountID: accountID, error: error)
			}
			pendingFolders[placeholder.id] = nil
			folderChanged(accountID: accountID)
			// Opened while it was on its way: open the folder the server made.
			if isOpen(placeholder) {
				if let real = mailboxes(of: accountID).first(where: { $0.parentId == parentID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
					sidebar = .mailbox(activeViewID == nil ? real.id : ViewMessageID.make(account: accountID, message: real.id))
				} else {
					focus = nil; sidebar = .allInboxes
				}
			}
		}
	}

	func renameFolder(accountID: String, mailbox: Mailbox, name: String) {
		guard let core, !Self.isPending(mailbox) else { return }
		let name = name.trimmingCharacters(in: .whitespaces)
		let key = Self.folderKey(accountID, mailbox.id)
		let before = Set(mailboxes(of: accountID).map(\.id))
		pendingRenames[key] = name
		folderChanged(accountID: accountID)
		Task {
			var failure: Error?
			do { try await core.renameFolder(accountId: accountID, mailboxId: mailbox.id, name: name) } catch { failure = error }
			pendingRenames[key] = nil
			folderChanged(accountID: accountID)
			if let failure { folderFailed("rename", mailbox.name, accountID: accountID, error: failure); return }
			// Over IMAP a folder's id is its path, so a renamed folder is a new id: keep it open.
			if isOpen(mailbox), let moved = mailboxes(of: accountID).filter({ !before.contains($0.id) && $0.parentId == mailbox.parentId }).first {
				sidebar = .mailbox(moved.id)
			}
		}
	}

	func deleteFolder(accountID: String, mailbox: Mailbox) {
		guard let core, !Self.isPending(mailbox) else { return }
		let key = Self.folderKey(accountID, mailbox.id)
		pendingDeletes.insert(key)
		if isOpen(mailbox) { focus = nil; sidebar = .allInboxes; reload() }
		folderChanged(accountID: accountID)
		Task {
			do {
				try await core.deleteFolder(accountId: accountID, mailboxId: mailbox.id)
			} catch {
				folderFailed("delete", mailbox.name, accountID: accountID, error: error)
			}
			pendingDeletes.remove(key)
			folderChanged(accountID: accountID)
		}
	}

	private func isOpen(_ mailbox: Mailbox) -> Bool {
		guard case let .mailbox(id) = sidebar else { return false }
		return id == mailbox.id || id.hasSuffix(mailbox.id)
	}

	private func folderChanged(accountID: String) {
		invalidateCaches()
		if accountID == account?.id { refreshMailboxes() }
	}

	private static func normalize(_ server: String) -> String {
		var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
		if !s.contains("://") {
			let local = s.hasPrefix("localhost") || s.hasPrefix("127.0.0.1")
			s = (local ? "http://" : "https://") + s
		}
		return s
	}

	private func activate(_ account: Account) {
		self.account = account
		accountList = (try? core?.accounts()) ?? [account]
		showAddAccount = false
		activeViewID = nil
		focus = nil
		banner = nil
		connectionNote = nil
		phase = .ready
		sidebar = .allInboxes
		selectedID = nil; detail = nil
		refreshMailboxes()
		reload()
		loadBrand()
		refreshLicenses()
		for a in accountList { loadAvatars(for: a); loadNames(for: a) }
		// Record what each inbox holds now, so only mail arriving after this is announced.
		for a in accountList { checkNewMail(accountID: a.id) }
		Task { await notifier.prepare() }
		sync()
		startPolling()
	}

	func switchAccount(_ target: Account) {
		guard target.id != account?.id else { return }
		stopPolling()
		reloadScratch()
		activate(target)
	}

	private func reloadScratch() {
		messages = []; mailboxes = []; identities = []; detail = nil; selectedID = nil
		compose = nil; minimizedDraft = nil; searchText = ""; scopeID = nil
		chat.reset()
		UserDefaults.standard.removeObject(forKey: "scopeInbox")
	}

	/// Signs out one saved account: the one in view the usual way, any other quietly in the background.
	func signOut(_ target: Account) {
		if target.id == account?.id { signOut(); return }
		try? core?.signOut(accountId: target.id)
		profiles.forget(target.id)
		quickReplies.forget(account: target.id)
		accountList = (try? core?.accounts()) ?? accountList.filter { $0.id != target.id }
		license.retain(accountIDs: accountList.map(\.id))
	}

	func signOut(notice: String? = nil) {
		stopPolling()
		if let id = account?.id { try? core?.signOut(accountId: id); profiles.forget(id); quickReplies.forget(account: id) }
		account = nil; mailboxes = []; identities = []; messages = []; detail = nil; selectedID = nil
		compose = nil; minimizedDraft = nil; searchText = ""; settingsPage = nil
		chat.reset()
		// VIPs and reminders belong to the account that was signed in.
		vips = []; reminders = [:]
		scopeID = nil; brandName = "Mailflare"
		license.retain(accountIDs: (try? core?.accounts().map(\.id)) ?? [])
		UserDefaults.standard.removeObject(forKey: "scopeInbox")
		UserDefaults.standard.removeObject(forKey: "vips")
		UserDefaults.standard.removeObject(forKey: "reminders")
		// Another saved account takes over; otherwise the sign-in window comes back.
		accountList = (try? core?.accounts()) ?? []
		if let next = accountList.first(where: { KeychainCredentialStore().load(accountId: $0.id) != nil }) {
			activate(next)
			return
		}
		phase = .signedOut
		banner = notice
		notifier.setBadge(0)
	}

	// MARK: Inbox views

	/// The account that holds a message, and the account's own id for it. Outside a view the id is plain.
	private func owner(of id: String) -> (account: String, message: String) {
		let parts = ViewMessageID.split(id)
		return (parts.account ?? accountID, parts.message)
	}

	/// The account a listed message belongs to; nil for the account in view outside a view.
	func accountID(of message: MessageSummary) -> String? { ViewMessageID.split(message.id).account }

	private static func tagged(_ detail: MessageDetail, id: String) -> MessageDetail {
		var copy = detail
		copy.summary.id = id
		return copy
	}

	@ObservationIgnored private var identityCache: [String: [Identity]] = [:]

	func identities(forAccount id: String) -> [Identity] {
		if id == account?.id { return identities }
		if let cached = identityCache[id] { return cached }
		let loaded = (try? core?.identities(accountId: id)) ?? []
		identityCache[id] = loaded
		return loaded
	}

	/// The addresses a draft can be sent from: those of the account it is written in.
	func identities(for draft: ComposeDraft) -> [Identity] { draft.accountID.map(identities(forAccount:)) ?? identities }

	private static func loadInboxViews() -> [InboxView] {
		guard let data = UserDefaults.standard.data(forKey: "inboxViews") else { return [] }
		return (try? JSONDecoder().decode([InboxView].self, from: data)) ?? []
	}

	private func persistInboxViews() {
		UserDefaults.standard.set(try? JSONEncoder().encode(inboxViews), forKey: "inboxViews")
	}

	func saveInboxView(_ view: InboxView) {
		if let index = inboxViews.firstIndex(where: { $0.id == view.id }) { inboxViews[index] = view } else { inboxViews.append(view) }
		persistInboxViews()
		if activeViewID == view.id { pageLimit = pageSize; reload() }
	}

	func deleteInboxView(_ id: String) {
		inboxViews.removeAll { $0.id == id }
		persistInboxViews()
		if activeViewID == id { activeViewID = nil; focus = nil; selectedID = nil; detail = nil; pageLimit = pageSize; reload() }
	}

	// MARK: Custom tabs

	private static func loadCustomTabs() -> [CustomTab] {
		guard let data = UserDefaults.standard.data(forKey: "customTabs") else { return [] }
		return (try? JSONDecoder().decode([CustomTab].self, from: data)) ?? []
	}

	private func persistCustomTabs() {
		UserDefaults.standard.set(try? JSONEncoder().encode(customTabs), forKey: "customTabs")
		tabCounts.removeAll()
	}

	/// Today, or the custom tab with this id.
	func customTab(_ id: String) -> CustomTab? {
		id == CustomTab.today.id ? CustomTab.today : customTabs.first { $0.id == id }
	}

	func saveCustomTab(_ tab: CustomTab) {
		var tab = tab
		tab.name = tab.name.trimmingCharacters(in: .whitespaces)
		if let index = customTabs.firstIndex(where: { $0.id == tab.id }) { customTabs[index] = tab } else { customTabs.append(tab) }
		persistCustomTabs()
		if sidebar == .customTab(tab.id) { pageLimit = pageSize; reload() }
	}

	func deleteCustomTab(_ id: String) {
		customTabs.removeAll { $0.id == id }
		persistCustomTabs()
		if sidebar == .customTab(id) { sidebar = .allInboxes; selectedID = nil; detail = nil }
	}

	/// The Inbox mail of the scope the dropdown chose (the account in view, one of its inboxes, or an
	/// inbox view), as far back as the local store is read for derived lists.
	private func scopeInboxMessages() -> [MessageSummary] {
		if let view = activeView {
			var list: [MessageSummary] = []
			for account in view.accountIDs where accountList.contains(where: { $0.id == account }) {
				for box in mailboxes(of: account) where box.role == "inbox" && Self.isMember(box, of: account, in: view) {
					list += (try? fetch(account, .mailbox(id: box.id), limit: scanLimit).list) ?? []
				}
			}
			return list
		}
		let folder: Folder = currentInbox
			.flatMap { inbox in mailboxes.first { $0.parentId == inbox.id && $0.role == "inbox" } }
			.map { .mailbox(id: $0.id) } ?? .role(role: "inbox")
		return (try? fetch(accountID, folder, limit: scanLimit).list) ?? []
	}

	/// Unread mail a tab lists, over the scope the dropdown chose: the number on its sidebar row.
	func unreadCount(of tab: CustomTab) -> Int {
		_ = mailRevision
		let day = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
		let key = "\(activeViewID ?? "-")|\(scopeID ?? "-")|\(accountID)|\(tab.id)|\(tab.hashValue)|\(day)"
		if let hit = tabCounts[key] { return hit }
		let now = Date.now
		let count = scopeInboxMessages().filter { !$0.seen && tab.matches($0, now: now) }.count
		tabCounts[key] = count
		return count
	}

	/// How much of the current Inbox a tab being edited would list right now.
	func preview(of tab: CustomTab) -> (total: Int, unread: Int) {
		let now = Date.now
		let matching = scopeInboxMessages().filter { tab.matches($0, now: now) }
		return (matching.count, matching.filter { !$0.seen }.count)
	}

	/// Whether `box` of `account` is inside one of the view's inboxes.
	private static func isMember(_ box: Mailbox, of account: String, in view: InboxView) -> Bool {
		view.members.contains { $0.accountID == account && ($0.inboxID == nil || box.parentId == $0.inboxID) }
	}

	func selectView(_ id: String) {
		guard inboxViews.contains(where: { $0.id == id }) else { return }
		activeViewID = id
		focus = nil
		settingsPage = nil
		sidebar = .allInboxes
		searchText = ""
		selectedID = nil; detail = nil
		pageLimit = pageSize
		reload()
	}

	/// Opens `item` across every account (the sidebar's Unified section and the switcher's Unified Inbox).
	func selectAllAccounts(_ item: SidebarItem = .allInboxes) {
		activeViewID = Self.allAccountsID
		focus = nil
		settingsPage = nil
		sidebar = item
		searchText = ""
		selectedID = nil; detail = nil
		pageLimit = pageSize
		reload()
	}

	/// Opens `item` in one account (all of its inboxes), switching to the account first when needed.
	func openAccountItem(_ item: SidebarItem, accountID: String, inbox: Mailbox? = nil) {
		settingsPage = nil
		if accountID != account?.id, let target = accountList.first(where: { $0.id == accountID }) { switchAccount(target) }
		setScope(inbox?.id)
		sidebar = item
		searchText = ""
		selectedID = nil; detail = nil
		pageLimit = pageSize
		reload()
	}

	/// Custom folders and labels of an account, for the sidebar's Accounts section.
	func customFolders(of accountID: String, inbox: Mailbox? = nil) -> [Mailbox] {
		let boxes = mailboxes(of: accountID)
		if let inbox {
			return boxes.filter { $0.parentId == inbox.id && $0.role == nil && !$0.name.hasPrefix("[") }
				.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		}
		let addresses = Set(Self.addressMailboxes(in: boxes).map(\.id))
		return boxes.filter { $0.role == nil && !addresses.contains($0.id) && !$0.name.hasPrefix("[") }
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

	/// The system mailbox with `role` in an account, when it has one.
	func hasRole(_ role: String, accountID: String, inbox: Mailbox? = nil) -> Bool {
		mailboxes(of: accountID).contains { $0.role == role && (inbox == nil || $0.parentId == inbox?.id) }
	}

	/// Unread inbox mail in every account.
	var unreadAllAccounts: Int { accountList.filter { unifiedIncludes($0.id) }.reduce(0) { $0 + unreadCount(accountID: $1.id, inbox: nil) } }

	/// Unread inbox mail across the view's inboxes.
	func unreadCount(of view: InboxView) -> Int {
		view.members.reduce(0) { total, member in
			guard let inboxID = member.inboxID else { return total + unreadCount(accountID: member.accountID, inbox: nil) }
			guard let inbox = inboxAddresses(of: member.accountID).first(where: { $0.id == inboxID }) else { return total }
			return total + unreadCount(accountID: member.accountID, inbox: inbox)
		}
	}

	// MARK: Sync

	func sync(quick: Bool = false) {
		guard let core, account != nil else { return }
		let id = accountID
		if quick { quietSyncs.insert(id) }
		Task {
			// A failed IMAP quick sync sends no `syncFinished` to clear it.
			defer { if quick { quietSyncs.remove(id) } }
			do {
				if quick { try await core.syncQuick(accountId: id) } else { try await core.sync(accountId: id) }
				if quick { quickSyncEnded(id) }
				connectionNote = nil
			} catch let error as CoreError {
				guard account?.id == id else { return }
				switch error {
				case .Auth:
					// The server no longer accepts this device's key (revoked, or the password changed).
					endSession("Your session has ended. Sign in again.")
				case .Network:
					connectionNote = "Can’t reach the server. Showing saved mail."
				default:
					if !quick { banner = describe(error) }
				}
			} catch { if !quick { banner = describe(error) } }
		}
	}

	/// Back to the sign-in screen without discarding anything cached: signing in again to the
	/// same account replaces its key and the saved mail is still there.
	private func endSession(_ notice: String) {
		stopPolling()
		account = nil; mailboxes = []; identities = []; messages = []; detail = nil; selectedID = nil
		connectionNote = nil; isSyncing = false
		phase = .signedOut
		banner = notice
	}

	private func startPolling() {
		pollTask?.cancel()
		// Without this a hidden or occluded window is napped and the minute between polls can
		// stretch to many, so new mail would be announced late. Idle system sleep is still allowed.
		if pollActivity == nil {
			pollActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Checking for new mail")
		}
		pollTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(60))
				self?.pollAll()
			}
		}
	}

	private func stopPolling() {
		pollTask?.cancel()
		pollTask = nil
		if let pollActivity { ProcessInfo.processInfo.endActivity(pollActivity) }
		pollActivity = nil
	}

	/// A quick sync of the account in view and of every other saved account, so mail for any of
	/// them is noticed. Errors on the others are ignored; they show when that account is opened.
	private func pollAll() {
		sync(quick: true)
		guard let core else { return }
		let current = account?.id
		for other in accountList where other.id != current && KeychainCredentialStore().load(accountId: other.id) != nil {
			let id = other.id
			quietSyncs.insert(id)
			Task {
				try? await core.syncQuick(accountId: id)
				quickSyncEnded(id)
			}
		}
	}

	/// An IMAP quick sync reads only the inboxes and sends no `syncFinished`, so its new mail and
	/// unread counts are picked up here. After a JMAP sync this repeats `syncFinished`'s check, which
	/// announces nothing twice.
	private func quickSyncEnded(_ id: String) {
		quietSyncs.remove(id)
		scheduleRefresh(mailboxes: id == account?.id, list: id == account?.id, newMailOf: id)
	}

	/// Hands an account's inbox, across all of its addresses, to the notifier and refreshes the Dock badge.
	private func checkNewMail(accountID id: String) {
		guard let core, let account = accountList.first(where: { $0.id == id }) else { return }
		// Never synced yet: its first look must come after the first sync, or that sync's mail is announced.
		guard mailboxes(of: id).contains(where: { $0.role == "inbox" }) else { updateBadge(); return }
		let inbox = (try? core.messages(accountId: id, folder: .role(role: "inbox"), offset: 0, limit: 50)) ?? []
		notifier.process(accountID: id, inbox: inbox, accountLabel: accountList.count > 1 ? accountName(account) : nil)
		updateBadge()
	}

	/// The Dock badge counts unread inbox mail across every account.
	func updateBadge() {
		notifier.setBadge(accountList.reduce(0) { $0 + unreadCount(accountID: $1.id, inbox: nil) })
	}

	/// Opens a message from a notification: its account, the combined inbox, then the message.
	func openMessage(accountID: String, messageID: String) {
		NSApp.activate(ignoringOtherApps: true)
		NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
		guard phase == .ready else { return }
		settingsPage = nil
		if accountID != account?.id, let target = accountList.first(where: { $0.id == accountID }) { switchAccount(target) }
		searchText = ""; unreadOnly = false
		sidebar = .allInboxes
		setScope(nil)
		select(messageID)
	}

	func handle(_ event: CoreEvent) {
		switch event {
		case .syncStarted(let id): if id == account?.id, !quietSyncs.contains(id) { isSyncing = true }
		case .syncFinished(let id, let error):
			quietSyncs.remove(id)
			let current = id == account?.id
			// Sent mail may have just arrived, which is where names come from.
			scheduleRefresh(mailboxes: current, list: current || activeView?.accountIDs.contains(id) == true, names: current, newMailOf: id)
			if current {
				isSyncing = false
				// Failures are classified where `sync()` throws; a clean finish means we're connected.
				if error == nil { connectionNote = nil }
			}
		case .mailboxesChanged: scheduleRefresh(mailboxes: true)
		case .messagesChanged, .newMail: scheduleRefresh(list: true)
		case .outboxChanged: checkOutbox()
		case .messageSent(_, let subject): showToast("Message sent", detail: subject, icon: .check)
		}
	}

	private func checkOutbox() {
		guard let core, account != nil else { return }
		if let bad = (try? core.outbox(accountId: accountID))?.first(where: { $0.error != nil }) {
			toast = nil
			banner = "“\(bad.subject.isEmpty ? "A message" : bad.subject)” could not be sent: \(bad.error ?? "unknown error")"
		}
	}

	// MARK: Mailboxes

	func refreshMailboxes() {
		guard let core, account != nil else { return }
		mailboxes = (try? core.mailboxes(accountId: accountID)).map { overlayingFolderChanges($0, accountID: accountID) } ?? mailboxes
		identities = (try? core.identities(accountId: accountID)) ?? identities
		if let a = account { loadAvatars(for: a) }
		updateBadge()
		if let id = scopeID, !mailboxes.contains(where: { $0.id == id && $0.isAccount }) { setScope(nil) }
		if let scope = currentInbox {
			let starred = (try? core.messages(accountId: accountID, folder: .starred, offset: 0, limit: scanLimit)) ?? []
			flaggedCount = starred.filter(inScope).count
			inboxUnread = Int(mailboxes.first { $0.parentId == scope.id && $0.role == "inbox" }?.unreadEmails ?? 0)
		} else {
			flaggedCount = Int((try? core.messageCount(accountId: accountID, folder: .starred)) ?? 0)
			inboxUnread = Int((try? core.unreadCount(accountId: accountID, folder: .role(role: "inbox"))) ?? 0)
		}
	}

	// MARK: Favorites and sections

	/// Everything the sidebar can list below Today, by stable key. Favorites is a chosen subset; the
	/// rest are listed in the section below it, so nothing appears twice.
	static let defaultFavorites = ["inbox", "vips", "flagged", "remind", "drafts", "sent"]
	private static let systemKeys = ["inbox", "vips", "flagged", "remind", "drafts", "sent", "junk", "trash", "archive"]

	/// VIPs and reminders exist only on this Mac: neither the Mailflare server nor the core has them
	/// (no VIP list, no snooze). They stay hidden until a mail service supports them.
	static let supportsVIPs = false
	static let supportsReminders = false
	var supportsVIPs: Bool { Self.supportsVIPs }
	var supportsReminders: Bool { Self.supportsReminders }

	var favorites: [String] = UserDefaults.standard.stringArray(forKey: "favoriteItems") ?? MailStore.defaultFavorites
	var collapsedSections: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? [])

	func item(for key: String) -> SidebarItem? {
		switch key {
		case "inbox": return .allInboxes
		case "vips": return supportsVIPs ? .vips : nil
		case "flagged": return .flagged
		case "remind": return supportsReminders ? .remindMe : nil
		case "drafts": return .allDrafts
		case "sent": return .allSent
		case "junk": return .allJunk
		case "trash": return .allTrash
		case "archive": return .allArchive
		default:
			guard key.hasPrefix("folder:") else { return nil }
			let id = String(key.dropFirst("folder:".count))
			return mailbox(id) != nil ? .mailbox(id) : nil
		}
	}

	/// Gmail keeps its folders as labels, so its account gets a Labels section instead of folders in
	/// the main list. Recognised by its IMAP server (which also covers Google Workspace domains).
	var isGmail: Bool {
		guard let account, activeViewID == nil else { return false }
		let host = account.serverUrl.lowercased()
		let domain = account.email.split(separator: "@").last.map { $0.lowercased() } ?? ""
		return host.contains("gmail.com") || host.contains("googlemail.com") || domain == "gmail.com" || domain == "googlemail.com"
	}

	func isGmailAccount(_ account: Account) -> Bool {
		let host = account.serverUrl.lowercased()
		let domain = account.email.split(separator: "@").last.map { $0.lowercased() } ?? ""
		return host.contains("gmail.com") || host.contains("googlemail.com") || domain == "gmail.com" || domain == "googlemail.com"
	}

	/// The Gmail labels not already in Favorites.
	var labelKeys: [String] {
		guard isGmail else { return [] }
		let chosen = Set(favorites)
		return folderKeys.filter { !chosen.contains($0) }
	}

	/// Custom folders are listed when one inbox is in view, or when the account has only one.
	private var folderKeys: [String] {
		if let view = activeView { return viewFolderKeys(view) }
		guard currentInbox != nil || inboxAddresses.count <= 1 else { return [] }
		if inboxAddresses.isEmpty { return plainFolders.map { "folder:\($0.id)" } }
		return accounts.flatMap { children(of: $0) }.filter { $0.role == nil }.map { "folder:\($0.id)" }
	}

	/// The folders and labels of every account in a view, keyed by account and mailbox.
	private func viewFolderKeys(_ view: InboxView) -> [String] {
		view.accountIDs.flatMap { account -> [String] in
			let boxes = mailboxes(of: account)
			let members = view.members.filter { $0.accountID == account }
			let folders: [Mailbox]
			if Self.addressMailboxes(in: boxes).isEmpty {
				folders = boxes.filter { $0.role == nil && !$0.name.hasPrefix("[") }
			} else {
				let wanted = Set(members.compactMap(\.inboxID)), everything = members.contains { $0.inboxID == nil }
				folders = boxes.filter { box in
					guard box.role == nil, let parent = box.parentId else { return false }
					return everything || wanted.contains(parent)
				}
			}
			return folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
				.map { "folder:" + ViewMessageID.make(account: account, message: $0.id) }
		}
	}

	/// Folders and labels of a single-inbox account (IMAP): top-level mailboxes without a role, minus
	/// the provider's non-selectable containers such as Gmail's "[Gmail]".
	private var plainFolders: [Mailbox] {
		mailboxes.filter { $0.role == nil && !$0.name.hasPrefix("[") }
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

	/// Where a message can be moved: grouped by inbox when there are several, one flat list otherwise.
	var moveTargets: [(title: String?, boxes: [Mailbox])] {
		if inboxAddresses.isEmpty {
			let system = mailboxes.filter { $0.role != nil }.sorted {
				(Self.roleOrder.firstIndex(of: $0.role ?? "") ?? 99) < (Self.roleOrder.firstIndex(of: $1.role ?? "") ?? 99)
			}
			return [(nil, system + plainFolders)]
		}
		return accounts.map { (inboxAddresses.count > 1 ? label($0) : nil, children(of: $0)) }
	}

	/// The favorites that still exist, in the user's order.
	var favoriteKeys: [String] { favorites.filter { item(for: $0) != nil } }

	/// Everything not in Favorites, in the usual order.
	var otherKeys: [String] {
		let chosen = Set(favorites)
		// Gmail's labels have their own section.
		return (Self.systemKeys + (isGmail ? [] : folderKeys)).filter { !chosen.contains($0) && item(for: $0) != nil }
	}

	/// Moves `key` into Favorites (before `before`, or at the end) or back out of it.
	func moveItem(_ key: String, toFavorites: Bool, before: String? = nil) {
		guard item(for: key) != nil else { return }
		var list = favorites.filter { $0 != key }
		if toFavorites {
			if let before, let index = list.firstIndex(of: before) { list.insert(key, at: index) } else { list.append(key) }
		}
		favorites = list
		UserDefaults.standard.set(list, forKey: "favoriteItems")
	}

	func toggleSection(_ id: String) {
		if collapsedSections.contains(id) { collapsedSections.remove(id) } else { collapsedSections.insert(id) }
		UserDefaults.standard.set(Array(collapsedSections), forKey: "collapsedSections")
	}

	// MARK: Inbox scope (one address, or all of them)

	/// Address mailboxes: top-level mailboxes holding an inbox of their own. Mailflare has one per
	/// address; Gmail and other single-inbox providers have none, so nothing says "All" for them.
	static func addressMailboxes(in list: [Mailbox]) -> [Mailbox] {
		let owners = Set(list.filter { $0.role == "inbox" }.compactMap(\.parentId))
		return list.filter { $0.isAccount && owners.contains($0.id) }.sorted { $0.sortOrder < $1.sortOrder }
	}

	var inboxAddresses: [Mailbox] { Self.addressMailboxes(in: mailboxes) }

	/// True only when several inboxes are combined in the view, the one case that is "All …".
	var showsAllInboxes: Bool { activeViewID != nil || (currentInbox == nil && inboxAddresses.count > 1) }
	var currentInbox: Mailbox? { scopeID.flatMap { id in inboxAddresses.first { $0.id == id } } }

	/// What the sidebar header shows: the chosen inbox, "All Inboxes", or the only inbox there is.
	var scopeTitle: String {
		if let view = activeView { return view.name }
		if let inbox = currentInbox { return label(inbox) }
		if inboxAddresses.count == 1 { return label(inboxAddresses[0]) }
		if inboxAddresses.isEmpty, let account { return accountName(account) }
		return account.map(switcherName) ?? "Inboxes"
	}

	func setScope(_ id: String?) {
		scopeID = id
		activeViewID = nil
		focus = nil
		if let id { UserDefaults.standard.set(id, forKey: "scopeInbox") } else { UserDefaults.standard.removeObject(forKey: "scopeInbox") }
		if case .mailbox = sidebar { sidebar = .allInboxes }
		pageLimit = pageSize
		refreshMailboxes()
		reload()
	}

	/// Whether a message belongs to the chosen inbox (always true when scoped to all).
	private func inScope(_ m: MessageSummary) -> Bool {
		guard let scope = scopeInbox?.id else { return true }
		return mailbox(m.mailboxId)?.parentId == scope
	}

	/// A system folder within the chosen inbox, or across all inboxes.
	private func scopedFolder(_ role: String) -> Folder {
		if let inbox = scopeInbox, let leaf = mailboxes.first(where: { $0.parentId == inbox.id && $0.role == role }) {
			return .mailbox(id: leaf.id)
		}
		return .role(role: role)
	}

	// MARK: Accounts and their inboxes (the switcher)

	/// Address mailboxes of any saved account, read from the local store.
	func inboxAddresses(of accountID: String) -> [Mailbox] {
		if accountID == account?.id { return inboxAddresses }
		return Self.addressMailboxes(in: mailboxes(of: accountID))
	}

	/// Unread in an address's inbox, or across all of an account's inboxes when `inbox` is nil.
	func unreadCount(accountID: String, inbox: Mailbox?) -> Int {
		_ = mailRevision
		guard let core else { return 0 }
		return mailboxes(of: accountID).filter { $0.role == "inbox" && (inbox == nil || $0.parentId == inbox?.id) }.reduce(0) { $0 + Int($1.unreadEmails) }
	}

	/// Switches to `inbox` (or all of the account's inboxes), changing account first when needed.
	func selectInbox(_ inbox: Mailbox?, accountID: String) {
		if accountID != account?.id, let target = accountList.first(where: { $0.id == accountID }) { switchAccount(target) }
		setScope(inbox?.id)
	}

	// MARK: Names

	/// Display names learned from the user's own sent mail, by lower-cased address. Providers like
	/// Gmail and iCloud name an account after its address, so the name the user's mail goes out under
	/// is what they actually call themselves.
	var knownNames: [String: String] = [:]

	private static func nameKey(_ email: String) -> String { "name.\(email.lowercased())" }

	/// An inbox's label: a name the mailbox carries, else the sent-mail name, else the part before the @.
	/// Inboxes of one account that would share a label (`info@` on several domains) show their address.
	func label(_ address: Mailbox) -> String {
		let name = ownLabel(address)
		let shared = inboxAddresses(of: address.accountId).contains { $0.id != address.id && ownLabel($0) == name }
		return shared ? address.inboxEmail : name
	}

	private func ownLabel(_ address: Mailbox) -> String {
		let own = address.inboxLabel
		let email = address.inboxEmail
		let bare = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
		guard own == bare else { return own }
		return knownNames[email.lowercased()] ?? own
	}

	/// An account's name: the server's when it has one (IMAP accounts are named after their address),
	/// else the sent-mail name, else the part before the @.
	func accountName(_ account: Account) -> String {
		if let own = profiles.localName(account.id) { return own }
		guard account.displayName.contains("@") else { return account.displayName }
		return knownNames[account.email.lowercased()] ?? account.shownName
	}

	/// An account's name in the switcher. An account with several inboxes keeps a name set here or by
	/// the server; otherwise it takes its primary inbox's (the first), which carries the name the
	/// mailbox was given ("Full Name <me@x.com>"). That comes before a name learned from sent mail,
	/// which can be just the part of the address before the @.
	func switcherName(_ account: Account) -> String {
		let inboxes = inboxAddresses(of: account.id)
		guard let primary = inboxes.first, inboxes.count > 1 else { return accountName(account) }
		if profiles.localName(account.id) != nil || !account.displayName.contains("@") { return accountName(account) }
		return label(primary)
	}

	/// Learns names from the Sent folder: each of the user's own addresses is paired with the display
	/// name its sent mail carries, and cached for the next launch. Safe to repeat; it reads local mail.
	func loadNames(for account: Account) {
		guard let core else { return }
		let defaults = UserDefaults.standard
		let addresses = [account.email] + inboxAddresses(of: account.id).map(\.inboxEmail)
		for email in addresses {
			if let cached = defaults.string(forKey: Self.nameKey(email)), knownNames[email.lowercased()] == nil {
				knownNames[email.lowercased()] = cached
			}
		}
		let own = Set(addresses.map { $0.lowercased() })
		let sent = (try? core.messages(accountId: account.id, folder: .role(role: "sent"), offset: 0, limit: 60)) ?? []
		for message in sent {
			let email = message.fromEmail.lowercased()
			let name = message.fromName.trimmingCharacters(in: .whitespaces)
			guard own.contains(email), !name.isEmpty, name.lowercased() != email, knownNames[email] != name else { continue }
			knownNames[email] = name
			defaults.set(name, forKey: Self.nameKey(email))
		}
	}

	/// Starts loading profile pictures for an account and its inboxes (once per launch).
	func loadAvatars(for account: Account) {
		avatars.load(key: AvatarCache.key(account: account.id), account: account, mailboxID: nil, email: account.email)
		for inbox in inboxAddresses(of: account.id) {
			avatars.load(key: AvatarCache.key(account: account.id, mailbox: inbox.id), account: account, mailboxID: inbox.id, email: inbox.inboxEmail)
		}
	}

	// MARK: Brand

	func loadBrand() {
		guard let account else { return }
		let key = "brand.\(account.id)"
		brandName = UserDefaults.standard.string(forKey: key) ?? "Mailflare"
		let id = account.id
		Task {
			guard let json = await Self.fetchBranding(of: account), self.account?.id == id else { return }
			guard let name = json["appName"] as? String else { return }
			brandName = name.isEmpty ? "Mailflare" : name
			UserDefaults.standard.set(brandName, forKey: key)
		}
	}

	/// A server with an active Pro or Team license activates the app for as long as the account is
	/// signed in, so every saved account is asked, not only the one in view.
	func refreshLicenses() {
		license.retain(accountIDs: accountList.map(\.id))
		for account in accountList {
			Task {
				guard let json = await Self.fetchBranding(of: account),
					  let licensed = json["canCustomizeBranding"] as? Bool else { return }
				license.setServerLicensed(licensed, accountID: account.id, brandName: json["appName"] as? String)
			}
		}
	}

	private nonisolated static func fetchBranding(of account: Account) async -> [String: Any]? {
		var parts = URLComponents(string: account.serverUrl.contains("://") ? account.serverUrl : "https://\(account.serverUrl)")
		guard parts?.host != nil, ["http", "https"].contains(parts?.scheme ?? "") else { return nil }
		parts?.path = "/api/branding"; parts?.query = nil; parts?.fragment = nil
		guard let url = parts?.url,
			  let (data, response) = try? await URLSession.shared.data(from: url),
			  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
		return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
	}

	static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

	/// The address sections the sidebar lists: the chosen inbox only, or all of them.
	var accounts: [Mailbox] { currentInbox.map { [$0] } ?? inboxAddresses }

	private static let roleOrder = ["inbox", "drafts", "sent", "junk", "trash", "archive"]

	/// Folders first, then system mailboxes in Mail's order.
	func children(of account: Mailbox) -> [Mailbox] {
		let kids = mailboxes.filter { $0.parentId == account.id }
		let folders = kids.filter { $0.role == nil }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		let system = kids.filter { $0.role != nil }.sorted {
			(Self.roleOrder.firstIndex(of: $0.role ?? "") ?? 99) < (Self.roleOrder.firstIndex(of: $1.role ?? "") ?? 99)
		}
		return folders + system
	}

	/// A mailbox of the account in view, or (as `ViewMessageID`) of another account in an inbox view.
	func mailbox(_ id: String) -> Mailbox? {
		let parts = ViewMessageID.split(id)
		guard let account = parts.account else { return mailboxes.first { $0.id == id } }
		return mailboxes(of: account).first { $0.id == parts.message }
	}
	/// Everything in an inbox view is inbox mail, from accounts whose mailboxes are not loaded here.
	func role(of message: MessageSummary) -> String? {
		guard activeViewID != nil, let account = ViewMessageID.split(message.id).account else { return mailbox(message.mailboxId)?.role }
		return mailboxes(of: account).first { $0.id == message.mailboxId }?.role
	}

	func unreadCount(for item: SidebarItem) -> Int {
		switch item {
		case .allInboxes: activeView.map(unreadCount(of:)) ?? inboxUnread
		case .flagged: activeViewID == nil ? flaggedCount : 0
		case .mailbox(let id): mailbox(id).map { $0.role == "drafts" ? 0 : Int($0.unreadEmails) } ?? 0
		case .smartToday: unreadCount(of: .today)
		case .customTab(let id): customTab(id).map(unreadCount(of:)) ?? 0
		default: 0
		}
	}

	/// What a sidebar group narrowed the list to: its inbox, or inside a view, its account and inbox.
	private var focusLabel: String? {
		guard let focus, let owner = accountList.first(where: { $0.id == focus.accountID }) else { return nil }
		if let id = focus.inboxID, let inbox = inboxAddresses(of: owner.id).first(where: { $0.id == id }) {
			return activeView == nil ? label(inbox) : "\(switcherName(owner)) / \(label(inbox))"
		}
		return activeView == nil ? nil : accountName(owner)
	}

	private func scopedTitle(_ base: String, all: String) -> String {
		if let focusLabel { return "\(base) — \(focusLabel)" }
		if showsAllInboxes { return all }
		return currentInbox.map { "\(base) — \(label($0))" } ?? base
	}

	var title: String {
		if let view = activeView {
			let base: String? = switch sidebar {
			case .allDrafts: "Drafts"
			case .allSent: "Sent"
			case .allJunk: "Spam"
			case .allTrash: "Trash"
			case .allArchive: "Archive"
			case .flagged: "Starred"
			case .smartToday: "Today"
			case .mailbox(let id): mailbox(id)?.name
			case .allInboxes: focus == nil ? nil : "Inbox"
			case .customTab(let id): customTab(id)?.name
			case .vips, .remindMe: nil
			}
			let scope = focusLabel ?? view.name
			return base.map { "\($0) — \(scope)" } ?? scope
		}
		switch sidebar {
		case .mailbox(let id):
			guard let box = mailbox(id) else { return "Mailflare" }
			let parent = box.parentId.flatMap(mailbox)?.name ?? ""
			return parent.isEmpty ? box.name : "\(box.name) — \(parent)"
		case .allInboxes: return scopedTitle("Inbox", all: "Inboxes")
		case .vips: return "VIPs"
		case .flagged: return focusLabel.map { "Starred — \($0)" } ?? "Starred"
		case .remindMe: return "Remind Me"
		case .allDrafts: return scopedTitle("Drafts", all: "Drafts")
		case .allSent: return scopedTitle("Sent", all: "Sent")
		case .allJunk: return scopedTitle("Spam", all: "Spam")
		case .allTrash: return scopedTitle("Trash", all: "Trash")
		case .allArchive: return scopedTitle("Archive", all: "Archive")
		case .smartToday: return "Today"
		case .customTab(let id): return customTab(id)?.name ?? "Mailflare"
		}
	}

	var subtitle: String { "\(total) message\(total == 1 ? "" : "s")" }

	// MARK: Listing (local store reads; the core keeps it current)

	/// The core folder that backs the sidebar item, or nil for items derived in memory.
	private var folder: Folder? {
		switch sidebar {
		case .allInboxes: scopedFolder("inbox")
		case .allDrafts: scopedFolder("drafts")
		case .allSent: scopedFolder("sent")
		case .allJunk: scopedFolder("junk")
		case .allTrash: scopedFolder("trash")
		case .allArchive: scopedFolder("archive")
		case .flagged: scopeInbox == nil ? .starred : nil
		case .mailbox(let id): .mailbox(id: id)
		case .vips, .remindMe, .smartToday, .customTab: nil
		}
	}

	private func matchesSidebar(_ m: MessageSummary) -> Bool {
		switch sidebar {
		case .allInboxes: role(of: m) == "inbox" && inScope(m)
		case .allDrafts: role(of: m) == "drafts" && inScope(m)
		case .allSent: role(of: m) == "sent" && inScope(m)
		case .allJunk: role(of: m) == "junk" && inScope(m)
		case .allTrash: role(of: m) == "trash" && inScope(m)
		case .allArchive: role(of: m) == "archive" && inScope(m)
		case .flagged: m.flagged && inScope(m)
		case .mailbox(let id): m.mailboxId == id
		case .vips: vips.contains(m.fromEmail.lowercased()) && inScope(m)
		case .remindMe: reminders[m.id] != nil && inScope(m)
		case .smartToday: role(of: m) == "inbox" && CustomTab.today.matches(m) && inScope(m)
		case .customTab(let id): role(of: m) == "inbox" && inScope(m) && (customTab(id)?.matches(m) ?? false)
		}
	}

	func reload() {
		guard let core, account != nil else { return }
		resetOlderIfListChanged()
		if activeView != nil { reloadView(); return }
		let id = accountID
		let q = searchText.trimmingCharacters(in: .whitespaces)
		var list: [MessageSummary]
		var count: Int?
		do {
			if !q.isEmpty {
				list = try core.search(accountId: id, query: q, limit: 300).filter(matchesSidebar)
			} else if sidebar == .remindMe {
				list = reminders.keys.compactMap { try? core.messageSummary(accountId: id, messageId: $0) }.filter(inScope).sorted { $0.receivedAt > $1.receivedAt }
			} else if let folder, !unreadOnly {
				let page = try fetch(id, folder, limit: UInt32(pageLimit))
				list = page.list
				count = page.count
			} else {
				// Derived or filtered views scan a wide local window of the right folder.
				let source = folder ?? (sidebar == .flagged ? .starred : scopedFolder("inbox"))
				list = try fetch(id, source, limit: scanLimit).list.filter(matchesSidebar)
			}
		} catch {
			banner = describe(error)
			return
		}
		if unreadOnly { list = list.filter { !$0.seen } }
		list = keepingOpened(list)
		messages = list
		total = count ?? list.count
		// Only a plain folder pages; search, filters and lists worked out in memory do not.
		let pages = q.isEmpty && !unreadOnly && sidebar != .remindMe
		setOlderSources(pages ? folder.map { [OlderSource(account: id, folder: $0)] } ?? [] : [])
	}

	// MARK: Opened mail stays listed

	/// Unread mail opened from the list, as it was listed (unread), by the id it is listed under.
	@ObservationIgnored private var opened: [String: MessageSummary] = [:]
	@ObservationIgnored private var openedContext = ""

	/// What the list is of: the same context keeps the opened mail, any other forgets it.
	private var listContext: String {
		"\(sidebar)|\(activeViewID ?? "")|\(scopeID ?? "")|\(String(describing: focus))|\(account?.id ?? "")|\(searchText)|\(unreadOnly)"
	}

	/// A list of unread mail (Today, a tab with an unread rule, the unread filter) would lose a message
	/// the moment it is read, and the reader with it. So mail opened from the list stays in it, as it
	/// was, until the list is of something else or is opened again. Mail that left for another reason
	/// (moved, archived, deleted) stays gone.
	private func keepingOpened(_ list: [MessageSummary]) -> [MessageSummary] {
		let context = listContext
		if context != openedContext { opened.removeAll(); openedContext = context }
		guard !opened.isEmpty, let core else { return list }
		var list = list
		let listed = Set(list.map(\.id))
		for (id, old) in opened {
			let (account, raw) = owner(of: id)
			guard !listed.contains(id), let now = try? core.messageSummary(accountId: account, messageId: raw),
				  now.seen, now.mailboxId == old.mailboxId else { opened[id] = nil; continue }
			// Shown as it is now (read), so the row loses its unread mark but stays where it was.
			var kept = now
			kept.id = id
			list.insert(kept, at: list.firstIndex { $0.receivedAt < old.receivedAt } ?? list.count)
		}
		return list
	}

	/// The view lists what "All Inboxes" does, across its inboxes: the same sidebar item, read from
	/// each account's local store through the shared list cache, merged newest first. Each message id
	/// carries its account (`ViewMessageID`).
	private func reloadView() {
		guard let view = loadView else { return }
		let q = searchText.trimmingCharacters(in: .whitespaces)
		let item = sidebar

		/// Whether `box` of `account` is inside one of the view's inboxes.
		func inView(_ account: String, _ box: Mailbox) -> Bool { Self.isMember(box, of: account, in: view) }
		func matches(_ account: String, _ m: MessageSummary) -> Bool {
			guard let box = mailboxes(of: account).first(where: { $0.id == m.mailboxId }), inView(account, box) else { return false }
			switch item {
			case .allInboxes: return box.role == "inbox"
			case .allDrafts: return box.role == "drafts"
			case .allSent: return box.role == "sent"
			case .allJunk: return box.role == "junk"
			case .allTrash: return box.role == "trash"
			case .allArchive: return box.role == "archive"
			case .flagged: return m.flagged
			case .smartToday: return box.role == "inbox" && CustomTab.today.matches(m)
			case .customTab(let id): return box.role == "inbox" && (customTab(id)?.matches(m) ?? false)
			case .mailbox(let id): return ViewMessageID.split(id).message == m.mailboxId
			case .vips, .remindMe: return false
			}
		}

		let role: String? = switch item {
		case .allInboxes: "inbox"
		case .allDrafts: "drafts"
		case .allSent: "sent"
		case .allJunk: "junk"
		case .allTrash: "trash"
		case .allArchive: "archive"
		default: nil
		}
		// Role folders and single folders are paged from the store; the rest scan a wide window.
		var paged: [(account: String, folder: Folder)] = []
		var scanned: [(account: String, folder: Folder)] = []
		for account in view.accountIDs where accountList.contains(where: { $0.id == account }) {
			switch item {
			case .flagged: scanned.append((account, .starred))
			case .smartToday, .customTab, .vips, .remindMe:
				for box in mailboxes(of: account) where box.role == "inbox" && inView(account, box) { scanned.append((account, .mailbox(id: box.id))) }
			case .mailbox(let id):
				let parts = ViewMessageID.split(id)
				if parts.account == account { paged.append((account, .mailbox(id: parts.message))) }
			default:
				for box in mailboxes(of: account) where box.role == role && inView(account, box) { paged.append((account, .mailbox(id: box.id))) }
			}
		}

		let filtered = !q.isEmpty || unreadOnly || !scanned.isEmpty
		var list: [MessageSummary] = []
		var count = 0
		do {
			if !q.isEmpty, let core {
				for account in view.accountIDs where accountList.contains(where: { $0.id == account }) {
					list += try core.search(accountId: account, query: q, limit: 300).filter { matches(account, $0) }.map { tag($0, account) }
				}
			} else {
				for source in paged {
					let page = try fetch(source.account, source.folder, limit: filtered ? scanLimit : UInt32(pageLimit))
					list += page.list.map { tag($0, source.account) }
					count += page.count
				}
				for source in scanned {
					list += try fetch(source.account, source.folder, limit: scanLimit).list.filter { matches(source.account, $0) }.map { tag($0, source.account) }
				}
			}
		} catch {
			banner = describe(error)
			return
		}
		if unreadOnly { list = list.filter { !$0.seen } }
		list.sort { $0.receivedAt > $1.receivedAt }
		if !filtered { list = Array(list.prefix(pageLimit)) }
		list = keepingOpened(list)
		messages = list
		total = filtered ? list.count : count
		setOlderSources(filtered || !q.isEmpty ? [] : paged.map { OlderSource(account: $0.account, folder: $0.folder) })
	}

	private func tag(_ message: MessageSummary, _ account: String) -> MessageSummary {
		var tagged = message
		tagged.id = ViewMessageID.make(account: account, message: message.id)
		return tagged
	}

	// MARK: Local reads, shared

	/// What the local store returned for a folder, kept until mail changes. Every list (an inbox on its
	/// own, an inbox view, the sidebar counts) reads through these, so a folder already read for one is
	/// not read again for another. Nothing here touches the network: syncing fills the store.
	@ObservationIgnored private var listCache: [String: (limit: UInt32, list: [MessageSummary], count: Int)] = [:]
	@ObservationIgnored private var mailboxCache: [String: [Mailbox]] = [:]

	private func invalidateCaches() {
		mailRevision += 1
		dropCaches()
	}

	private func dropCaches() {
		tabCounts.removeAll()
		listCache.removeAll()
		mailboxCache.removeAll()
	}

	private struct PendingRefresh {
		var mailboxes = false
		var list = false
		var names = false
		/// Accounts whose inbox goes to the notifier, after the mailboxes are read again.
		var newMail: Set<String> = []
	}
	/// What the next coalesced refresh re-reads; nil when none is scheduled.
	@ObservationIgnored private var pendingRefresh: PendingRefresh?

	/// Core events come in bursts (a sync reports mailboxes, then messages, then its end, for each
	/// account), and each one used to re-read the store on the main thread and redraw the list and
	/// sidebar. Caches are dropped at once, so direct reads stay current; the re-reads and the
	/// sidebar's recount (`mailRevision`) run once for the whole burst.
	private func scheduleRefresh(mailboxes: Bool = false, list: Bool = false, names: Bool = false, newMailOf account: String? = nil) {
		dropCaches()
		let scheduled = pendingRefresh != nil
		var pending = pendingRefresh ?? PendingRefresh()
		pending.mailboxes = pending.mailboxes || mailboxes
		pending.list = pending.list || list
		pending.names = pending.names || names
		if let account { pending.newMail.insert(account) }
		pendingRefresh = pending
		guard !scheduled else { return }
		Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(50))
			guard let self, let pending = self.pendingRefresh else { return }
			self.pendingRefresh = nil
			self.mailRevision += 1
			if pending.mailboxes { self.refreshMailboxes() }
			if pending.names, let current = self.account { self.loadNames(for: current) }
			for id in pending.newMail { self.checkNewMail(accountID: id) }
			if pending.list { self.reload() }
		}
	}

	private func fetch(_ accountID: String, _ folder: Folder, limit: UInt32) throws -> (list: [MessageSummary], count: Int) {
		guard let core else { return ([], 0) }
		let key = "\(accountID)|\(folder)"
		if let hit = listCache[key], hit.limit >= limit { return (Array(hit.list.prefix(Int(limit))), hit.count) }
		let list = try core.messages(accountId: accountID, folder: folder, offset: 0, limit: limit)
		let count = Int(try core.messageCount(accountId: accountID, folder: folder))
		listCache[key] = (limit, list, count)
		return (list, count)
	}

	/// Any saved account's mailboxes: the account in view from memory, the others from the store once.
	func mailboxes(of accountID: String) -> [Mailbox] {
		if accountID == account?.id { return mailboxes }
		if let cached = mailboxCache[accountID] { return cached }
		let loaded = overlayingFolderChanges((try? core?.mailboxes(accountId: accountID)) ?? [], accountID: accountID)
		mailboxCache[accountID] = loaded
		return loaded
	}

	// MARK: Loading older mail

	/// A folder the list pages through, in one account.
	struct OlderSource {
		var account: String
		var folder: Folder
	}

	/// Where older mail for the list in view can come from once the local store runs out. Empty for
	/// lists worked out in memory (search, filters, smart lists), which have nothing to page.
	private(set) var olderSources: [OlderSource] = []
	/// Older mail is being read in from the server.
	private(set) var isLoadingMore = false
	/// The server had nothing older for this list.
	private(set) var reachedEnd = false
	/// The last attempt to read older mail failed; it is tried again only when asked (Retry).
	private(set) var loadMoreFailed = false
	/// The list the state above belongs to (`listContext`); another list starts it over.
	@ObservationIgnored private var olderContext = ""

	/// Whether there is more of the list to show: further down the local store, or on the server.
	var canLoadMore: Bool { messages.count < total || (!reachedEnd && !olderSources.isEmpty) }

	/// The list is empty for now but mail is on its way, so it shows placeholder rows, not "No Messages".
	var isAwaitingMail: Bool { messages.isEmpty && (isSyncing || isLoadingMore || (canLoadMore && !loadMoreFailed)) }

	/// Starts the older-mail state over when the list is of something else.
	private func resetOlderIfListChanged() {
		let context = listContext
		guard context != olderContext else { return }
		olderContext = context
		olderTask?.cancel(); olderTask = nil
		isLoadingMore = false; reachedEnd = false; loadMoreFailed = false
	}

	/// How many messages the server says a folder holds, when the mailboxes say.
	private func serverTotal(_ source: OlderSource) -> Int? {
		let boxes = mailboxes(of: source.account)
		switch source.folder {
		case .mailbox(let id): return boxes.first { $0.id == id }.map { Int($0.totalEmails) }
		case .role(let role): return boxes.filter { $0.role == role }.reduce(0) { $0 + Int($1.totalEmails) }
		case .starred: return nil
		}
	}

	/// Sets where older mail comes from after a reload, leaving out folders the store already holds
	/// in full, and fetches at once when the list came up empty.
	private func setOlderSources(_ sources: [OlderSource]) {
		olderSources = sources.filter { source in
			guard let server = serverTotal(source) else { return true }
			let local = (try? fetch(source.account, source.folder, limit: 1).count) ?? 0
			return local < server
		}
		if messages.isEmpty { Task { [weak self] in self?.fetchOlder() } }
	}

	/// Keeps the list ahead of the reader, given how many listed rows are below the viewport and how
	/// many rows a screen holds. The next local page is added while a couple of screens are left, which
	/// is instant. Older mail is asked of the server sooner, while several screens of local mail are
	/// still unread, because some servers take seconds to answer.
	func loadMore(rowsBelow: Int, screenRows: Int) {
		let screen = max(screenRows, 1)
		let localBelow = rowsBelow + (total - messages.count)
		if rowsBelow < 2 * screen, messages.count < total {
			pageLimit += pageSize
			reload()
		}
		if localBelow < 4 * screen { fetchOlder() }
	}

	/// Reads older mail of every source from the server in the background. The list grows from the
	/// store as it is scrolled; the spinner below the last row shows only if the reader gets there first.
	private func fetchOlder() {
		guard let core, !isLoadingMore, !reachedEnd, !loadMoreFailed, !olderSources.isEmpty else { return }
		let sources = olderSources, context = listContext, before = total
		isLoadingMore = true
		olderTask = Task { [weak self] in
			// Sources in different accounts don't wait on each other.
			let results = await withTaskGroup(of: UInt32?.self) { group in
				for source in sources {
					group.addTask { try? await core.fetchOlder(accountId: source.account, folder: source.folder) }
				}
				return await group.reduce(into: [UInt32?]()) { $0.append($1) }
			}
			guard let self, !Task.isCancelled, self.olderContext == context else { return }
			let fetched = results.reduce(0) { $0 + ($1 ?? 0) }
			self.olderTask = nil
			self.isLoadingMore = false
			if fetched > 0 {
				self.invalidateCaches()
				self.reload()
				// Rows the store already held: nothing older came, so don't ask again.
				if self.total <= before { self.reachedEnd = true }
			} else if results.contains(where: { $0 == nil }) {
				self.loadMoreFailed = true
			} else {
				self.reachedEnd = true
			}
		}
	}

	/// Tries again after reading older mail failed.
	func retryLoadMore() {
		loadMoreFailed = false
		fetchOlder()
	}

	func sidebarChanged() {
		pageLimit = pageSize
		reload()
	}

	/// Re-derives `adaptColors` for the selected sender: their own choice, else the Settings default.
	func refreshAdaptColors() {
		adaptColors = MessageAppearance.adapts(sender: selectedMessage?.fromEmail ?? "")
	}

	func toggleAdaptColors() {
		adaptColors.toggle()
		if let sender = selectedMessage?.fromEmail { MessageAppearance.setAdapts(adaptColors, sender: sender) }
	}

	var selectedMessage: MessageSummary? { selectedID.flatMap { id in messages.first { $0.id == id } } }

	/// Whether Reply All would reach anyone beyond Reply: the reply target (Reply-To, else the
	/// sender) and every To/Cc recipient, less this account's own addresses, come to more than one.
	/// False until the body has loaded.
	var canReplyAll: Bool {
		guard let detail, detail.summary.id == selectedID else { return false }
		let mine = Set(identities(forAccount: owner(of: detail.summary.id).account).map { $0.email.lowercased() })
		let target = detail.replyTo.isEmpty ? [detail.summary.fromEmail] : detail.replyTo.map(\.email)
		let everyone = target + (detail.to + detail.cc).map(\.email)
		return Set(everyone.map { $0.lowercased() }).subtracting(mine).count > 1
	}

	// MARK: Selection and body

	func select(_ id: String?) {
		multiSelection = []
		guard id != selectedID else { return }
		selectedID = id
		detail = nil
		refreshAdaptColors()
		detailTask?.cancel()
		markReadTask?.cancel()
		guard let id, let core else { return }
		if let m = messages.first(where: { $0.id == id }), !m.seen {
			if openedContext != listContext { opened.removeAll(); openedContext = listContext }
			opened[id] = m
			scheduleMarkRead(id)
		}
		let (acct, raw) = owner(of: id)
		if let cached = try? core.cachedMessage(accountId: acct, messageId: raw) { detail = Self.tagged(cached, id: id); return }
		detailTask = Task { [weak self] in
			do {
				let d = try await core.loadMessage(accountId: acct, messageId: raw)
				if !Task.isCancelled, self?.selectedID == id { self?.detail = Self.tagged(d, id: id) }
			} catch { if !Task.isCancelled { self?.banner = describe(error) } }
		}
	}

	// MARK: Multiple selection

	/// Shift click: everything between the anchor and `id`.
	func extendSelection(to id: String) {
		guard let anchor = selectedID, let from = messages.firstIndex(where: { $0.id == anchor }),
			  let to = messages.firstIndex(where: { $0.id == id }) else { select(id); return }
		let range = messages[min(from, to)...max(from, to)].map(\.id)
		if range.count < 2 { select(id); return }
		multiSelection = Set(range)
	}

	/// Command click: adds `id` to the picked messages, or takes it out.
	func toggleSelection(of id: String) {
		var picked = multiSelection.isEmpty ? Set(selectedID.map { [$0] } ?? []) : multiSelection
		if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
		switch picked.count {
		case 0: select(nil)
		case 1: select(picked.first)
		default: multiSelection = picked
		}
	}

	/// The messages an action from the list applies to: the picked ones when `id` is among them.
	func actionIDs(for id: String) -> [String] {
		multiSelection.contains(id) ? messages.map(\.id).filter(multiSelection.contains) : [id]
	}

	/// Runs `work` once per account for these messages, then refreshes and keeps a sensible selection.
	private func bulk(_ ids: [String], _ work: (_ account: String, _ raw: [String]) throws -> Void) {
		guard !ids.isEmpty else { return }
		var byAccount: [String: [String]] = [:]
		for id in ids { let o = owner(of: id); byAccount[o.account, default: []].append(o.message) }
		let next = ids.count == 1 ? nextSelection(after: ids[0]) : nil
		attempt { for (account, raw) in byAccount { try work(account, raw) } }
		reload()
		refreshMailboxes()
		multiSelection = []
		if let current = selectedID, !messages.contains(where: { $0.id == current }) {
			selectedID = nil; detail = nil
			select(next)
		}
	}

	func archive(ids: [String]) { moveToRole(ids, "archive") }
	func junk(ids: [String]) { moveToRole(ids, "junk") }
	private func moveToRole(_ ids: [String], _ role: String) {
		bulk(ids) { account, raw in _ = try core?.moveMessages(accountId: account, messageIds: raw, target: .role(role: role)) }
	}
	func trash(ids: [String]) {
		bulk(ids) { account, raw in _ = try core?.deleteMessages(accountId: account, messageIds: raw) }
	}
	/// Flags them all, or unflags them all when each is already flagged.
	func toggleFlag(ids: [String]) {
		let flagged = !ids.allSatisfy { id in messages.first { $0.id == id }?.flagged ?? false }
		bulk(ids) { account, raw in try core?.setFlagged(accountId: account, messageIds: raw, flagged: flagged) }
	}
	/// Marks them all read, or all unread when each is already read.
	func toggleRead(ids: [String]) {
		let read = !ids.allSatisfy { id in messages.first { $0.id == id }?.seen ?? true }
		bulk(ids) { account, raw in try core?.setSeen(accountId: account, messageIds: raw, seen: read) }
		if read { for id in ids { notifier.clear(messageID: owner(of: id).message) } }
	}

	/// AI summaries by listed-message id, loaded from the core's database or just made.
	var summaries: [String: String] = [:]
	/// The message being summarized, and why the last attempt failed.
	var summarizingID: String?
	var summaryError: String?

	func loadSavedSummary(for id: String) {
		summaryError = nil
		let (acct, raw) = owner(of: id)
		if let saved = (try? core?.aiSummary(accountId: acct, messageId: raw)) ?? nil { summaries[id] = saved }
	}

	/// Summarizes the open message with the AI provider and saves the result with the message.
	func summarizeSelected() {
		guard summarizingID == nil, let detail, let id = selectedID, detail.summary.id == id, let client = ai.client else { return }
		summarizingID = id
		summaryError = nil
		let subject = detail.summary.subject, from = detail.summary.sender.formatted
		let text = PreviewText.plain(detail.html)
		let (acct, raw) = owner(of: id)
		Task { [weak self] in
			do {
				let result = try await AISummarizer.summarize(client: client, subject: subject, from: from, text: text)
				try? self?.core?.saveAiSummary(accountId: acct, messageId: raw, text: result)
				self?.summaries[id] = result
			} catch { self?.summaryError = error.localizedDescription }
			self?.summarizingID = nil
		}
	}

	/// Marks an opened message read as the Reading setting says: at once, after a delay, or never.
	private func scheduleMarkRead(_ id: String) {
		let delay = ReadingSettings.markReadDelay
		if delay == 0 { setRead(id, true); return }
		guard delay > 0 else { return }
		markReadTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(delay))
			if !Task.isCancelled, self?.selectedID == id { self?.setRead(id, true) }
		}
	}

	// MARK: Actions (the core applies locally at once and replays them to the server)

	private func attempt(_ work: () throws -> Void) {
		invalidateCaches()
		do { try work() } catch { banner = describe(error) }
	}

	private func nextSelection(after id: String) -> String? {
		guard let i = messages.firstIndex(where: { $0.id == id }) else { return nil }
		return messages.indices.contains(i + 1) ? messages[i + 1].id : (i > 0 ? messages[i - 1].id : nil)
	}

	/// Runs a change that may remove the message from the current list, keeping a sensible selection.
	private func leaving(_ id: String, _ work: () throws -> Void) {
		let next = nextSelection(after: id)
		attempt(work)
		reload()
		refreshMailboxes()
		if selectedID == id, !messages.contains(where: { $0.id == id }) {
			selectedID = nil; detail = nil
			select(next)
		}
	}

	func setRead(_ id: String, _ read: Bool) {
		let (acct, raw) = owner(of: id)
		attempt { try core?.setSeen(accountId: acct, messageIds: [raw], seen: read) }
		if read { notifier.clear(messageID: raw) }
		reload(); refreshMailboxes()
	}

	func toggleFlag(_ id: String) {
		guard let m = messages.first(where: { $0.id == id }) else { return }
		let (acct, raw) = owner(of: id)
		leaving(id) { try core?.setFlagged(accountId: acct, messageIds: [raw], flagged: !m.flagged) }
	}

	func move(_ id: String, to box: Mailbox) {
		let (acct, raw) = owner(of: id)
		leaving(id) { _ = try core?.moveMessages(accountId: acct, messageIds: [raw], target: .mailbox(id: box.id)) }
	}

	func archive(_ id: String) { moveToRole(id, "archive") }
	func junk(_ id: String) { moveToRole(id, "junk") }
	private func moveToRole(_ id: String, _ role: String) {
		let (acct, raw) = owner(of: id)
		leaving(id) { _ = try core?.moveMessages(accountId: acct, messageIds: [raw], target: .role(role: role)) }
	}
	/// Moves to Trash, or deletes permanently from Trash and Drafts.
	func trash(_ id: String) {
		let (acct, raw) = owner(of: id)
		leaving(id) { _ = try core?.deleteMessages(accountId: acct, messageIds: [raw]) }
	}

	// VIPs and reminders live on this Mac only; the server has no such concept.

	func toggleVIP(_ address: EmailAddress) {
		let e = address.email.lowercased()
		if vips.contains(e) { vips.remove(e) } else { vips.insert(e) }
		UserDefaults.standard.set(Array(vips), forKey: "vips")
		if sidebar == .vips { reload() }
	}

	func isVIP(_ address: EmailAddress?) -> Bool { address.map { vips.contains($0.email.lowercased()) } ?? false }

	/// Senders blocked on this Mac: their mail is moved to Spam when blocked.
	private(set) var blockedSenders: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "blockedSenders") ?? [])

	/// Blocks `address` and moves its messages in the list to Spam.
	func block(_ address: EmailAddress, messageID: String) {
		let email = address.email.lowercased()
		blockedSenders.insert(email)
		UserDefaults.standard.set(Array(blockedSenders), forKey: "blockedSenders")
		let ids = messages.filter { $0.fromEmail.lowercased() == email && role(of: $0) != "junk" }.map(\.id)
		for id in ids where id != messageID { junk(id) }
		junk(messageID)
		banner = "Blocked \(address.display)"
	}

	func remind(_ id: String, at date: Date?) {
		reminders[id] = date
		if date == nil { reminders.removeValue(forKey: id) }
		UserDefaults.standard.set(reminders.mapValues(\.timeIntervalSince1970), forKey: "reminders")
		if sidebar == .remindMe { reload() }
	}

	// MARK: Compose

	/// The message whose raw source is open in the Original Message popup.
	var original: MessageSummary?

	/// The raw message (headers and MIME body) and the cached file it came from. The core's
	/// attachment download takes `<message id>#raw` for this: the server's own blob on JMAP, a full
	/// fetch over IMAP.
	func loadOriginal(_ id: String) async throws -> (source: String, path: String) {
		guard let core else { throw CoreError.InvalidInput(message: "No account is open.") }
		let (acct, raw) = owner(of: id)
		let blob = Attachment(blobId: "\(raw)#raw", name: "original-\(raw).eml", mimeType: "message/rfc822", size: 0)
		let path = try await core.downloadAttachment(accountId: acct, attachment: blob)
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		return (String(decoding: data, as: UTF8.self), path)
	}

	/// A message put away with the composer's minimize button; the Compose button reopens it.
	var minimizedDraft: ComposeDraft?

	func minimize(_ draft: ComposeDraft) {
		minimizedDraft = draft
		compose = nil
	}

	func newMessage() {
		if let draft = minimizedDraft {
			minimizedDraft = nil
			compose = draft
			return
		}
		var d = ComposeDraft()
		d.identityID = (scopeID.flatMap { scope in identities.first { $0.id.hasPrefix(scope + "~") } } ?? identities.first)?.id
		d.body = profiles.signatureHTML(accountID)
		compose = d
	}

	private func draft(from t: ComposeTemplate, title: String, accountID acct: String) -> ComposeDraft {
		var d = ComposeDraft()
		d.title = title
		d.accountID = acct
		d.identityID = t.identityId ?? identities(forAccount: acct).first?.id
		d.to = Addresses.format(t.to); d.cc = Addresses.format(t.cc); d.bcc = Addresses.format(t.bcc)
		d.subject = t.subject
		d.inReplyTo = t.inReplyTo
		d.references = t.references
		d.attachments = t.attachments
		d.replacesDraftID = t.replacesDraftId
		// A saved draft already carries the signature it was written with.
		d.body = title == "Draft" || !t.bodyHtml.isEmpty ? t.bodyHtml : profiles.signatureHTML(acct)
		d.quotedHTML = t.quotedHtml
		return d
	}

	func reply(to id: String, all: Bool) { template(id, title: all ? "Reply All" : "Reply") { try await $0.composeTemplate(accountId: $1, messageId: $2, kind: all ? .replyAll : .reply) } }
	func forward(_ id: String) { template(id, title: "Forward") { try await $0.composeTemplate(accountId: $1, messageId: $2, kind: .forward) } }
	/// Opens a draft the assistant wrote as it was then, not as the saved draft is now.
	func openChatDraft(_ saved: ChatDraft) {
		var d = ComposeDraft()
		d.title = saved.isReply ? "Reply" : "New Message"
		d.accountID = saved.accountID
		d.identityID = saved.identityID
		d.to = saved.to; d.cc = saved.cc; d.bcc = saved.bcc
		d.subject = saved.subject
		d.body = saved.bodyHTML
		d.quotedHTML = saved.quotedHTML
		d.inReplyTo = saved.inReplyTo
		d.references = saved.references
		// Sending removes the saved copy; one already replaced or deleted is ignored.
		d.replacesDraftID = saved.draftID
		compose = d
	}

	func editDraft(_ id: String, title: String = "Draft") { template(id, title: title) { try await $0.draftTemplate(accountId: $1, messageId: $2) } }

	private func template(_ id: String, title: String, _ make: @escaping (MailCore, String, String) async throws -> ComposeTemplate) {
		guard let core else { return }
		let (acct, raw) = owner(of: id)
		Task {
			do { compose = draft(from: try await make(core, acct, raw), title: title, accountID: acct) } catch { banner = describe(error) }
		}
	}

	private func outgoing(_ d: ComposeDraft) throws -> OutgoingMessage {
		let available = identities(for: d)
		guard let identity = available.first(where: { $0.id == d.identityID }) ?? available.first else {
			throw CoreError.InvalidInput(message: "This account has no address to send from.")
		}
		return OutgoingMessage(
			identityId: identity.id, to: Addresses.parse(d.to), cc: Addresses.parse(d.cc), bcc: Addresses.parse(d.bcc),
			subject: d.subject, html: Self.html(of: d), inReplyTo: d.inReplyTo, references: d.references,
			attachments: d.attachments, replacesDraftId: d.replacesDraftID)
	}

	/// The body, then the quoted original below it.
	private static func html(of d: ComposeDraft) -> String {
		let body = d.body.isEmpty ? "<div><br></div>" : d.body
		return d.quotedHTML.isEmpty ? body : body + "<br>" + d.quotedHTML
	}

	let templates = ComposeTemplates()

	/// Closes the composer at once and queues the message. Only what can be checked here throws; a
	/// failure to queue reopens the composer.
	func commit(_ draft: ComposeDraft, send: Bool) throws {
		guard core != nil else { return }
		let message = try outgoing(draft)
		if send, message.to.isEmpty { throw CoreError.InvalidInput(message: "Add at least one valid recipient.") }
		compose = nil
		enqueue(message, accountID: draft.accountID ?? accountID, send: send) { [weak self] in
			guard let self else { return }
			// Back where it was, unless another message took the composer meanwhile.
			if compose == nil { compose = draft } else if minimizedDraft == nil { minimizedDraft = draft }
		}
	}

	/// Queues a message in the core's outbox off the main thread (queuing copies attachments). A
	/// failure to queue is reported and handed to `onFailure`; a failure to deliver surfaces through
	/// the outbox event.
	private func enqueue(_ message: OutgoingMessage, accountID acct: String, send: Bool, onSuccess: (() -> Void)? = nil, onFailure: @escaping () -> Void) {
		guard let core else { return }
		if send {
			// Stays up until the core reports the message sent, or that it could not be.
			showToast("Sending…", detail: message.subject, icon: .send, isProgress: true, duration: 60)
		}
		Task {
			do {
				try await Task.detached(priority: .userInitiated) {
					_ = send ? try core.send(accountId: acct, message: message) : try core.saveDraft(accountId: acct, message: message)
				}.value
				invalidateCaches()
				if !send { showToast("Draft saved", detail: message.subject, icon: .check) }
				onSuccess?()
			} catch {
				toast = nil
				banner = "“\(message.subject.isEmpty ? "Your message" : message.subject)” could not be \(send ? "sent" : "saved"): \(describe(error))"
				onFailure()
			}
		}
	}

	// MARK: Quick reply

	/// Replies typed in the reader's reply box, kept per message until sent.
	@ObservationIgnored private(set) var quickReplies = QuickReplies(file: nil)

	/// The key a listed message's reply is kept under.
	func quickReplyKey(_ id: String) -> String {
		let (acct, raw) = owner(of: id)
		return QuickReplies.key(account: acct, message: raw)
	}

	/// A reply sent from the reply box, shown at the end of the message it answers.
	struct SentReply: Identifiable {
		let id = UUID()
		let html: String
		let to: String
		let accountID: String
		let date: Date
	}

	/// A dropdown drawn by the window's root view, above every pane (including web views), with its
	/// bottom edge on top of `anchor`, a frame in the "mailflareRoot" coordinate space.
	struct OverlayMenu {
		var anchor: CGRect
		var content: AnyView
		var dismiss: () -> Void
	}

	var overlayMenu: OverlayMenu?

	/// Replies sent from the reply box this session, by the listed message they answer.
	private(set) var sentReplies: [String: [SentReply]] = [:]

	/// Sends `html` as a reply to a listed message, as the composer's Reply would: to the sender, with
	/// the subject, threading, signature and quoted original. The reply box keeps its text (and shows a
	/// spinner) until the core reports the reply sent: then `onSent` runs and the reply joins the
	/// message as a sent reply. If it can't be sent, `onFailure` runs and the text is still there.
	func sendQuickReply(to id: String, html: String, onSent: @escaping () -> Void, onFailure: @escaping () -> Void) {
		guard let core else { onFailure(); return }
		let (acct, raw) = owner(of: id)
		let key = quickReplyKey(id)
		showToast("Sending…", detail: messages.first { $0.id == id }.map { "Re: \($0.subject)" } ?? "", icon: .send, isProgress: true, duration: 60)
		Task {
			do {
				var reply = draft(from: try await core.composeTemplate(accountId: acct, messageId: raw, kind: .reply), title: "Reply", accountID: acct)
				// The template's body is the signature, which goes below what was written.
				reply.body = reply.body.isEmpty ? html : html + reply.body
				let message = try outgoing(reply)
				guard !message.to.isEmpty else { throw CoreError.InvalidInput(message: "This message has no address to reply to.") }
				let sent = SentReply(html: html, to: message.to.map(\.formatted).joined(separator: ", "), accountID: acct, date: .now)
				enqueue(message, accountID: acct, send: true, onSuccess: { [weak self] in
					guard let self else { return }
					quickReplies.set("", for: key)
					withAnimation(.snappy(duration: 0.35)) {
						self.sentReplies[id, default: []].append(sent)
						onSent()
					}
				}, onFailure: onFailure)
			} catch {
				toast = nil
				banner = "Your reply could not be sent: \(describe(error))"
				onFailure()
			}
		}
	}

	func showToast(_ title: String, detail: String = "", icon: AppIcon, isProgress: Bool = false, duration: Double = 3) {
		let item = Toast(title: title, detail: detail, icon: icon, isProgress: isProgress)
		toast = item
		toastTask?.cancel()
		toastTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(duration))
			if !Task.isCancelled, self?.toast?.id == item.id { self?.toast = nil }
		}
	}

	func suggestions(_ prefix: String) -> [EmailAddress] {
		guard let core, prefix.count >= 2 else { return [] }
		return (try? core.suggestContacts(accountId: accountID, prefix: prefix, limit: 5)) ?? []
	}

	// MARK: Attachments

	func save(_ attachment: Attachment) {
		guard let core else { return }
		let acct = selectedID.map { owner(of: $0).account } ?? accountID
		Task {
			do {
				let path = try await core.downloadAttachment(accountId: acct, attachment: attachment)
				let panel = NSSavePanel()
				panel.nameFieldStringValue = attachment.displayName
				if panel.runModal() == .OK, let url = panel.url {
					try? FileManager.default.removeItem(at: url)
					try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
				}
			} catch { banner = describe(error) }
		}
	}
}

extension String {
	var htmlEscaped: String {
		replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
	}
}
