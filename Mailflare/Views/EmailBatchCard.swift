import SwiftUI
import MailflareCore

/// The emails the assistant prepared, as a table in the chat: who each goes to and its subject, with a
/// tick to leave one out and a row that opens to read and edit it. Accepting sends them (or keeps them
/// as drafts); cancelling drops them. Nothing leaves the Mac before the user presses the button.
struct EmailBatchCard: View {
	@Environment(MailStore.self) private var store
	var runID: String
	@State private var editingID: String?

	private var chat: AIChatModel { store.chat }

	var body: some View {
		if let batch = chat.batch(runID) {
			VStack(alignment: .leading, spacing: 0) {
				header(batch)
				Rectangle().fill(AppTheme.cardStroke).frame(height: 1)
				columns
				ForEach(batch.items) { item in
					Rectangle().fill(AppTheme.cardStroke.opacity(0.7)).frame(height: 1)
					row(item, batch: batch)
				}
				Rectangle().fill(AppTheme.cardStroke).frame(height: 1)
				footer(batch).padding(10)
			}
			.background(AppTheme.composerContextFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
			.opacity(batch.state == .cancelled ? 0.6 : 1)
			.sheet(isPresented: Binding(get: { editingID != nil }, set: { if !$0 { editingID = nil } })) {
				if let id = editingID { EmailItemSheet(runID: runID, itemID: id) { editingID = nil } }
			}
		}
	}

	private func label(_ identity: Identity) -> String { identity.name.isEmpty ? identity.email : "\(identity.name) <\(identity.email)>" }

	/// Every address the user can send from: each signed-in account's own and its aliases.
	private var senders: [(accountID: String, identity: Identity)] {
		let accounts = (try? store.mailCore?.accounts()) ?? []
		let ids = accounts.isEmpty ? [store.currentAccountID] : accounts.map(\.id)
		return ids.flatMap { id in store.identities(forAccount: id).map { (id, $0) } }
	}

	@ViewBuilder
	private func fromView(_ batch: EmailBatch) -> some View {
		let options = senders
		if batch.state == .review, options.count > 1 {
			Menu {
				ForEach(options, id: \.identity.id) { option in
					Button {
						chat.updateBatch(runID) { $0.accountID = option.accountID; $0.identityID = option.identity.id; $0.from = option.identity.email }
					} label: {
						if option.identity.id == batch.identityID { Label(label(option.identity), systemImage: "checkmark") } else { Text(label(option.identity)) }
					}
				}
			} label: {
				Text("From \(batch.from)").font(Typography.meta).lineLimit(1)
			}
			.menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
			.help("Send from another address")
		} else {
			Text("From \(batch.from)").font(Typography.meta).foregroundStyle(.secondary).lineLimit(1)
		}
	}

	private func header(_ batch: EmailBatch) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text("\(batch.title) · \(batch.items.count) email\(batch.items.count == 1 ? "" : "s")").font(Typography.bodySemibold)
			fromView(batch)
		}
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var wide: Bool { store.chatExpanded }

	private var columns: some View {
		HStack(spacing: 8) {
			Color.clear.frame(width: 16)
			Text("To").frame(width: wide ? 140 : 100, alignment: .leading)
			if wide { Text("Email").frame(width: 220, alignment: .leading) }
			Text("Subject").frame(maxWidth: .infinity, alignment: .leading)
			Color.clear.frame(width: 44)
		}
		.font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
		.padding(.horizontal, 10).padding(.vertical, 5)
	}

	// MARK: Rows

	private func row(_ item: ProposedEmail, batch: EmailBatch) -> some View {
		let editable = batch.state == .review
		return HStack(spacing: 8) {
			if editable {
				Toggle("", isOn: Binding(
					get: { item.included },
					set: { value in chat.updateBatch(runID) { b in if let i = b.items.firstIndex(where: { $0.id == item.id }) { b.items[i].included = value } } }))
					.toggleStyle(.checkbox).controlSize(.small).labelsHidden()
					.frame(width: 16)
					.help(item.included ? "Leave this one out" : "Include this one")
			} else {
				Color.clear.frame(width: 16, height: 16)
			}
			if wide {
				Text(item.name.isEmpty ? "—" : item.name).font(Typography.notice).lineLimit(1)
					.frame(width: 140, alignment: .leading)
				Text(item.to).font(Typography.notice).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
					.frame(width: 220, alignment: .leading)
			} else {
				VStack(alignment: .leading, spacing: 0) {
					Text(item.name.isEmpty ? item.to : item.name).font(Typography.notice).lineLimit(1)
					if !item.name.isEmpty { Text(item.to).font(Typography.meta).foregroundStyle(.secondary).lineLimit(1) }
				}
				.frame(width: 100, alignment: .leading)
			}
			VStack(alignment: .leading, spacing: 0) {
				Text(item.subject).font(Typography.notice).lineLimit(1)
				if let error = item.error { Text(error).font(Typography.meta).foregroundStyle(.orange).lineLimit(2) }
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			statusMark(item)
				.frame(width: 14)
			Button { editingID = item.id } label: {
				Text(editable ? "Edit" : "View").font(Typography.meta.weight(.medium))
					.frame(width: 30)
			}
			.buttonStyle(.plain).foregroundStyle(Color.accentColor)
		}
		.padding(.horizontal, 10).padding(.vertical, 6)
		.opacity(editable && !item.included ? 0.45 : 1)
	}

	@ViewBuilder
	private func statusMark(_ item: ProposedEmail) -> some View {
		switch item.status {
		case .pending: Color.clear
		case .queued: HIcon(.check, size: 12).foregroundStyle(.green)
		case .failed: HIcon(.close, size: 12).foregroundStyle(.orange)
		}
	}

	// MARK: Footer

	@ViewBuilder
	private func footer(_ batch: EmailBatch) -> some View {
		switch batch.state {
		case .review:
			HStack(spacing: 6) {
				Spacer(minLength: 8)
				Button { chat.submitBatch(runID, send: false, store: store) } label: {
					if wide { Text("Save as drafts") } else { HIcon(.drafts, size: 14).frame(height: 16) }
				}
				.buttonStyle(.pill).disabled(batch.included == 0)
				.help("Save as drafts")
				Button { chat.submitBatch(runID, send: true, store: store) } label: {
					Text("Send \(batch.included) email\(batch.included == 1 ? "" : "s")")
				}
				.buttonStyle(.pillProminent).disabled(batch.included == 0)
			}
		case .sent: Text("Queued \(batch.items.filter { $0.status == .queued }.count) of \(batch.items.count) to send.").font(Typography.meta).foregroundStyle(.secondary)
		case .drafted: Text("Saved \(batch.items.filter { $0.status == .queued }.count) drafts. Find them in Drafts.").font(Typography.meta).foregroundStyle(.secondary)
		case .cancelled: Text("Cancelled. Nothing was sent.").font(Typography.meta).foregroundStyle(.secondary)
		}
	}
}

/// One proposed email in a window of its own: its address, subject and text to read, and to edit
/// until the batch is accepted.
private struct EmailItemSheet: View {
	@Environment(MailStore.self) private var store
	var runID: String
	var itemID: String
	var close: () -> Void

	private var chat: AIChatModel { store.chat }
	private var editable: Bool { chat.batch(runID)?.state == .review }

	private func field(_ keyPath: WritableKeyPath<ProposedEmail, String>) -> Binding<String> {
		Binding(
			get: { chat.batch(runID)?.items.first { $0.id == itemID }?[keyPath: keyPath] ?? "" },
			set: { value in chat.updateBatch(runID) { b in if let i = b.items.firstIndex(where: { $0.id == itemID }) { b.items[i][keyPath: keyPath] = value; b.items[i].status = b.items[i].status == .queued ? .queued : .pending; b.items[i].error = nil } } })
	}

	private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
		HStack(spacing: 8) {
			Text(title).font(Typography.meta).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
			content().font(Typography.notice)
		}
		.padding(.horizontal, 8).padding(.vertical, 6)
		.background(AppTheme.composerContextFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(editable ? "Edit email" : "Email").font(Typography.bodySemibold)
			if editable {
				labeled("To") { TextField("name@example.com", text: field(\.to)).textFieldStyle(.plain) }
				labeled("Subject") { TextField("Subject", text: field(\.subject)).textFieldStyle(.plain) }
				TextEditor(text: field(\.body))
					.font(Typography.notice).scrollContentBackground(.hidden)
					.frame(minHeight: 220, maxHeight: .infinity)
					.padding(6)
					.background(AppTheme.composerContextFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
					.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
			} else {
				labeled("To") { Text(field(\.to).wrappedValue).textSelection(.enabled) }
				labeled("Subject") { Text(field(\.subject).wrappedValue).textSelection(.enabled) }
				ScrollView {
					Text(field(\.body).wrappedValue).font(Typography.notice).textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading).padding(8)
				}
				.frame(minHeight: 220)
				.background(AppTheme.composerContextFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
			}
			HStack {
				Spacer()
				Button("Done", action: close).buttonStyle(.pillProminent).keyboardShortcut(.defaultAction)
			}
		}
		.padding(16)
		.frame(width: 520)
		.frame(maxHeight: 600)
	}
}
