import Foundation

/// The block structure of an assistant message: prose, headings, code, `>` quotes (wording the
/// assistant offers) and GitHub-style tables. Inline styling (bold, links, code spans) is left to
/// `AttributedString` when a block is drawn.
enum ChatBlock: Equatable {
	case prose(String)
	case heading(level: Int, text: String)
	case code(String)
	case quote(String)
	case table(ChatTable)
}

struct ChatTable: Equatable {
	enum Alignment { case leading, center, trailing }
	var header: [String]
	var alignments: [Alignment]
	var rows: [[String]]
}

enum ChatMarkdown {
	static func blocks(from text: String) -> [ChatBlock] {
		let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
		var blocks: [ChatBlock] = []
		var prose: [String] = []
		var quote: [String] = []

		func flushProse() {
			let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
			if !joined.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.prose(joined)) }
			prose = []
		}
		func flushQuote() {
			let joined = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
			if !joined.isEmpty { blocks.append(.quote(joined)) }
			quote = []
		}

		var index = 0
		while index < lines.count {
			let line = lines[index]
			let trimmed = line.trimmingCharacters(in: .whitespaces)

			// ``` fenced code, up to the closing fence (or the end, while it is still being written)
			if trimmed.hasPrefix("```") {
				flushProse(); flushQuote()
				var code: [String] = []
				index += 1
				while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
					code.append(lines[index]); index += 1
				}
				index += 1
				blocks.append(.code(code.joined(separator: "\n")))
				continue
			}

			// A table: a row of cells, then the |---|---| line under it.
			if isRow(trimmed), index + 1 < lines.count, let alignments = separator(lines[index + 1]) {
				flushProse(); flushQuote()
				let header = cells(trimmed)
				var rows: [[String]] = []
				index += 2
				while index < lines.count, isRow(lines[index].trimmingCharacters(in: .whitespaces)) {
					var row = cells(lines[index].trimmingCharacters(in: .whitespaces))
					if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
					rows.append(Array(row.prefix(max(header.count, 1))))
					index += 1
				}
				var aligned = alignments
				if aligned.count < header.count { aligned += Array(repeating: .leading, count: header.count - aligned.count) }
				blocks.append(.table(ChatTable(header: header, alignments: Array(aligned.prefix(header.count)), rows: rows)))
				continue
			}

			// # Heading
			if let heading = heading(trimmed) {
				flushProse(); flushQuote()
				blocks.append(.heading(level: heading.level, text: heading.text))
				index += 1
				continue
			}

			if trimmed.hasPrefix(">") {
				flushProse()
				var rest = trimmed.dropFirst()
				if rest.first == " " { rest = rest.dropFirst() }
				quote.append(String(rest))
			} else {
				flushQuote()
				prose.append(line)
			}
			index += 1
		}
		flushProse(); flushQuote()
		return blocks
	}

	// MARK: Pieces

	/// A line that looks like a table row: it has a pipe and is not only pipes and dashes of a separator.
	private static func isRow(_ line: String) -> Bool {
		line.contains("|") && !line.isEmpty && (line.hasPrefix("|") || line.filter { $0 == "|" }.count >= 1)
	}

	/// The alignments a `| --- | :---: | ---: |` line gives its columns, or nil when it is not one.
	private static func separator(_ line: String) -> [ChatTable.Alignment]? {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix("-") else { return nil }
		let parts = cells(trimmed)
		guard !parts.isEmpty else { return nil }
		var result: [ChatTable.Alignment] = []
		for part in parts {
			let cell = part.trimmingCharacters(in: .whitespaces)
			let body = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
			guard body.count >= 1, body.allSatisfy({ $0 == "-" }) else { return nil }
			switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
			case (true, true): result.append(.center)
			case (false, true): result.append(.trailing)
			default: result.append(.leading)
			}
		}
		return result
	}

	/// The cells of a row, without the outer pipes. `\|` stays inside a cell.
	static func cells(_ line: String) -> [String] {
		var text = line.trimmingCharacters(in: .whitespaces)
		if text.hasPrefix("|") { text.removeFirst() }
		if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
		var cells: [String] = []
		var current = ""
		var escaped = false
		for character in text {
			if escaped { current.append(character); escaped = false }
			else if character == "\\" { escaped = true; current.append(character) }
			else if character == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
			else { current.append(character) }
		}
		cells.append(current.trimmingCharacters(in: .whitespaces))
		return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
	}

	private static func heading(_ line: String) -> (level: Int, text: String)? {
		let hashes = line.prefix { $0 == "#" }
		guard (1...6).contains(hashes.count) else { return nil }
		let rest = line.dropFirst(hashes.count)
		guard rest.first == " " else { return nil }
		let text = rest.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#")))
		return text.isEmpty ? nil : (hashes.count, text)
	}
}
