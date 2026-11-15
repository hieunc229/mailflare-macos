import Foundation
import ServiceManagement

/// The pages of the Settings view, listed in the sidebar in this order.
enum SettingsPage: String, CaseIterable, Identifiable {
	case general, accounts, ai, mcp, notifications, license, support, about

	var id: String { rawValue }

	var title: String {
		switch self {
		case .general: "Preferences"
		case .notifications: "Notifications"
		case .accounts: "Accounts"
		case .ai: "AI Providers"
		case .mcp: "MCP Credentials"
		case .license: "License"
		case .support: "Support"
		case .about: "Version"
		}
	}

	var icon: AppIcon {
		switch self {
		case .general: .settings
		case .notifications: .bell
		case .accounts: .allInboxes
		case .ai: .sparkles
		case .mcp: .link
		case .license: .vip
		case .support: .support
		case .about: .info
		}
	}
}

/// How the sidebar groups the pages while Settings is open.
enum SettingsSection: CaseIterable, Identifiable {
	case general, about

	var id: Self { self }

	var title: String {
		switch self {
		case .general: "General"
		case .about: "About"
		}
	}

	var pages: [SettingsPage] {
		switch self {
		case .general: [.general, .accounts, .notifications, .ai, .mcp]
		case .about: [.license, .support, .about]
		}
	}
}

/// Keys and defaults of the preferences that code outside the Settings view reads.
enum ReadingSettings {
	static let markReadDelayKey = "markReadDelay"
	static let loadRemoteContentKey = "loadRemoteContent"
	static let autoCheckUpdatesKey = "autoCheckUpdates"
	static let showAvatarsKey = "showListAvatars"
	static let offlineDepthKey = "offlineDepth"

	/// How many messages of each folder are kept on this Mac for offline reading and search.
	static var offlineDepth: Int { UserDefaults.standard.object(forKey: offlineDepthKey) as? Int ?? 1000 }

	/// Whether the message list shows a sender avatar beside each row.
	static var showAvatars: Bool { UserDefaults.standard.object(forKey: showAvatarsKey) as? Bool ?? true }

	/// Seconds before an opened message is marked read: 0 at once, -1 never.
	static var markReadDelay: Int { UserDefaults.standard.object(forKey: markReadDelayKey) as? Int ?? 0 }
	static var autoCheckUpdates: Bool { UserDefaults.standard.object(forKey: autoCheckUpdatesKey) as? Bool ?? true }
}

enum LaunchAtLogin {
	static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

	/// Registers or removes the login item; returns whether the system now agrees.
	@discardableResult
	static func set(_ enabled: Bool) -> Bool {
		do {
			if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
		} catch {}
		return isEnabled == enabled
	}
}
