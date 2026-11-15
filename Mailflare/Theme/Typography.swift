import SwiftUI

/// One reading size for everything the user reads or types (rows, message content, inputs).
/// An explicit point size rather than a semantic style, because `.body`, `.callout` and
/// `.subheadline` resolve to three different sizes on macOS. Metadata (dates, badges) is a step down.
enum Typography {
	static let baseSize: CGFloat = 14
	/// Extra space between lines in the assistant chat: a line height of 1.5 times the size.
	static let chatLineSpacing: CGFloat = baseSize * 0.5 - 3
	/// Space between a run of text and anything else in an answer (tables, steps, code): 1.5 lines.
	static let chatBlockGap: CGFloat = 20
	static let body = Font.system(size: baseSize, weight: .regular)
	static let bodySemibold = Font.system(size: baseSize, weight: .semibold)
	static let notice = Font.system(size: baseSize - 1, weight: .regular)
	static let meta = Font.system(size: baseSize - 2, weight: .regular)
}
