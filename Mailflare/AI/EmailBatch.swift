import Foundation

/// One email the assistant proposed, as a row of the review table.
struct ProposedEmail: Codable, Identifiable, Equatable {
	enum Status: String, Codable { case pending, queued, failed }

	var id = UUID().uuidString
	var name: String
	var to: String
	var subject: String
	var body: String
	/// Rows the user unticks are left out when the batch is accepted.
	var included = true
	var status: Status = .pending
	var error: String?
}

/// Emails the assistant prepared for several people, held for the user to read, edit and accept.
/// Nothing is sent or saved until they choose; accepting hands each row to the core's outbox.
struct EmailBatch: Codable, Equatable {
	enum State: String, Codable { case review, sent, drafted, cancelled }

	var id = UUID().uuidString
	var title: String
	var accountID: String
	var identityID: String
	/// The address they go out from, shown above the table.
	var from: String
	var items: [ProposedEmail]
	var state: State = .review

	var included: Int { items.filter(\.included).count }
}
