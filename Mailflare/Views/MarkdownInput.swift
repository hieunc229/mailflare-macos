import AppKit
import SwiftUI

/// The assistant's message box: plain text that is styled as Markdown while it is typed. `- ` and
/// `* ` at the start of a line become a bullet (`• `), and Return inside a list starts the next item
/// (on an empty item it ends the list). Anywhere else Return sends and Shift+Return starts a line.
/// The text keeps its bullets; `markdown(from:)` turns them back into `- ` for sending.
struct MarkdownInput: NSViewRepresentable {
	@Binding var text: String
	@Binding var height: CGFloat
	/// Counts up to ask for keyboard focus.
	var focusRequest: Int
	var maxLines = 6
	var onSubmit: () -> Void

	/// The message as Markdown: bullets written as `- `.
	static func markdown(from text: String) -> String {
		text.replacingOccurrences(of: "(?m)^([ \\t]*)• ", with: "$1- ", options: .regularExpression)
	}

	static let baseFont = NSFont.systemFont(ofSize: Typography.baseSize)

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSScrollView {
		let scroll = NSScrollView()
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.borderType = .noBorder
		let view = NSTextView()
		view.delegate = context.coordinator
		view.isRichText = false
		view.allowsUndo = true
		view.drawsBackground = false
		view.isAutomaticQuoteSubstitutionEnabled = false
		view.isAutomaticDashSubstitutionEnabled = false
		view.textContainerInset = .zero
		view.textContainer?.lineFragmentPadding = 0
		view.isVerticallyResizable = true
		view.isHorizontallyResizable = false
		view.autoresizingMask = [.width]
		view.textContainer?.widthTracksTextView = true
		view.insertionPointColor = .controlAccentColor
		// Files dropped on the panel are attached; the text view must not paste their paths instead.
		view.unregisterDraggedTypes()
		scroll.documentView = view
		context.coordinator.textView = view
		view.string = text
		context.coordinator.restyle()
		DispatchQueue.main.async { context.coordinator.measure() }
		return scroll
	}

	func updateNSView(_ scroll: NSScrollView, context: Context) {
		let coordinator = context.coordinator
		coordinator.parent = self
		guard let view = coordinator.textView else { return }
		if view.string != text {
			view.string = text
			coordinator.restyle()
			DispatchQueue.main.async { coordinator.measure() }
		}
		if coordinator.lastFocusRequest != focusRequest {
			coordinator.lastFocusRequest = focusRequest
			DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
		}
	}

	@MainActor
	final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: MarkdownInput
		weak var textView: NSTextView?
		var lastFocusRequest = 0

		init(_ parent: MarkdownInput) { self.parent = parent }

		func textDidChange(_ notification: Notification) {
			guard let view = textView else { return }
			parent.text = view.string
			restyle()
			measure()
		}

		/// The height the text needs, up to the line limit, handed back to the layout.
		func measure() {
			guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
			layout.ensureLayout(for: container)
			let used = layout.usedRect(for: container).height
			let line = Self.lineHeight
			let height = min(max(used, line), line * CGFloat(parent.maxLines))
			if abs(parent.height - height) > 0.5 { parent.height = height }
		}

		static var lineHeight: CGFloat {
			MarkdownInput.baseFont.boundingRectForFont.height + Typography.chatLineSpacing
		}

		// MARK: Keys and list typing

		func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
			let newlines: [Selector] = [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
										#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))]
			guard newlines.contains(selector) else { return false }
			// Shift+Return (however the system names it) starts a new line; Return alone sends.
			let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
			if shiftHeld || selector != #selector(NSResponder.insertNewline(_:)) {
				textView.insertText("\n", replacementRange: textView.selectedRange())
				return true
			}
			let text = textView.string as NSString
			let caret = textView.selectedRange().location
			let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
			let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
			let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) == true
			if !commandHeld, let marker = Self.listMarker(in: line) {
				if marker.content.isEmpty {
					// An empty item ends the list.
					let range = NSRange(location: lineRange.location, length: (line as NSString).length)
					if textView.shouldChangeText(in: range, replacementString: "") {
						textView.replaceCharacters(in: range, with: "")
						textView.didChangeText()
					}
				} else {
					let next = marker.next
					let range = NSRange(location: caret, length: 0)
					if textView.shouldChangeText(in: range, replacementString: "\n" + next) {
						textView.replaceCharacters(in: range, with: "\n" + next)
						textView.didChangeText()
					}
				}
				return true
			}
			parent.onSubmit()
			return true
		}

		/// `- ` and `* ` typed at the start of a line turn into a bullet as the space is typed.
		func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
			guard replacementString == " ", range.length == 0 else { return true }
			let text = textView.string as NSString
			let lineRange = text.lineRange(for: range)
			let before = text.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
			guard let marker = before.last, marker == "-" || marker == "*",
				  before.dropLast().allSatisfy({ $0 == " " || $0 == "\t" }) else { return true }
			let replace = NSRange(location: range.location - 1, length: 1)
			if textView.shouldChangeText(in: replace, replacementString: "• ") {
				textView.replaceCharacters(in: replace, with: "• ")
				textView.didChangeText()
			}
			return false
		}

		/// The list marker a line starts with, what follows it, and the marker for the next line.
		static func listMarker(in line: String) -> (content: String, next: String)? {
			let indent = String(line.prefix { $0 == " " || $0 == "\t" })
			let rest = String(line.dropFirst(indent.count))
			if rest.hasPrefix("• ") { return (String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces), indent + "• ") }
			if let dot = rest.firstIndex(of: "."), let n = Int(rest[..<dot]), rest[rest.index(after: dot)...].hasPrefix(" ") {
				let content = String(rest[rest.index(dot, offsetBy: 2)...]).trimmingCharacters(in: .whitespaces)
				return (content, indent + "\(n + 1). ")
			}
			return nil
		}

		// MARK: Styling

		/// Styles the whole text as Markdown: headings, bullet and numbered lists, **bold**, *italic*
		/// and `code`. The marks stay in the text and are only dimmed.
		func restyle() {
			guard let view = textView, let storage = view.textStorage else { return }
			let full = NSRange(location: 0, length: storage.length)
			let base = MarkdownInput.baseFont
			let paragraph = NSMutableParagraphStyle()
			paragraph.lineSpacing = Typography.chatLineSpacing
			let dim = NSColor.tertiaryLabelColor
			storage.beginEditing()
			storage.setAttributes([.font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: full)
			let text = storage.string as NSString

			text.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
				let line = text.substring(with: range)
				if let heading = line.range(of: "^#{1,3} ", options: .regularExpression) {
					let level = line.distance(from: heading.lowerBound, to: heading.upperBound) - 1
					let size = [17.0, 16.0, 15.0][level - 1]
					storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: range)
					storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: range.location, length: level))
				}
				if let marker = Self.listMarker(in: line) {
					let markerLength = (line as NSString).length - (marker.content as NSString).length
					let list = NSMutableParagraphStyle()
					list.lineSpacing = Typography.chatLineSpacing
					list.headIndent = 16
					list.firstLineHeadIndent = 0
					storage.addAttribute(.paragraphStyle, value: list, range: range)
					let markerRange = NSRange(location: range.location, length: min(markerLength, range.length))
					storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: markerRange)
					// A bullet is drawn larger, with more room before the text.
					if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("• ") {
						let bullet = NSRange(location: range.location + line.prefix { $0 == " " || $0 == "\t" }.count, length: 1)
						storage.addAttribute(.font, value: NSFont.systemFont(ofSize: MarkdownInput.baseFont.pointSize * 1.5), range: bullet)
						storage.addAttribute(.kern, value: 4, range: bullet)
					}
				}
				if line.hasPrefix("> ") {
					storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
				}
			}

			func style(_ pattern: String, marks: Int, _ apply: (NSRange) -> [NSAttributedString.Key: Any]) {
				guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
				for match in regex.matches(in: storage.string, range: full) {
					let range = match.range
					guard range.length > marks * 2 else { continue }
					storage.addAttributes(apply(range), range: range)
					storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: range.location, length: marks))
					storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: range.location + range.length - marks, length: marks))
				}
			}
			let bold = NSFont.systemFont(ofSize: base.pointSize, weight: .semibold)
			let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
			let mono = NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular)
			style("\\*\\*[^*\\n]+\\*\\*", marks: 2) { _ in [.font: bold] }
			style("(?<![*\\w])\\*[^*\\n]+\\*(?![*\\w])", marks: 1) { _ in [.font: italic] }
			style("`[^`\\n]+`", marks: 1) { _ in [.font: mono, .backgroundColor: NSColor.quaternaryLabelColor] }
			storage.endEditing()
			view.typingAttributes = [.font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
		}
	}
}
