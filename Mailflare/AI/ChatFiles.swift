import AppKit
import Foundation
import PDFKit

/// A file the user attached to the chat. A copy is kept on this Mac, so the assistant can read it
/// with `read_file` in later turns and a saved chat still has it.
struct ChatAttachment: Codable, Identifiable, Equatable {
	enum Kind: String, Codable { case table, text, pdf, document, image }

	var id: String
	var name: String
	var kind: Kind
	/// What the model is told about it up front: the kind, its size, and for a table its columns.
	var summary: String
}

enum ChatFiles {
	struct Failure: LocalizedError {
		let message: String
		var errorDescription: String? { message }
	}

	static let maxBytes = 25 * 1_024 * 1_024
	static let tableExtensions: Set<String> = ["csv", "tsv"]
	static let textExtensions: Set<String> = ["txt", "md", "markdown", "json", "xml", "log", "yaml", "yml", "html", "htm", "eml", "ics", "vcf"]
	static let documentExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt"]
	static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

	private static var root: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("Mailflare/ChatFiles", isDirectory: true)
	}

	private static func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

	private static func stored(_ attachment: ChatAttachment) -> URL { folder(attachment.id).appendingPathComponent(attachment.name) }

	// MARK: Attaching

	/// Copies the file into the chat's storage and describes it.
	static func ingest(_ url: URL) throws -> ChatAttachment {
		let name = url.lastPathComponent
		let ext = url.pathExtension.lowercased()
		let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
		guard size <= maxBytes else { throw Failure(message: "\(name) is larger than 25 MB.") }
		let kind: ChatAttachment.Kind
		if tableExtensions.contains(ext) { kind = .table }
		else if textExtensions.contains(ext) { kind = .text }
		else if ext == "pdf" { kind = .pdf }
		else if documentExtensions.contains(ext) { kind = .document }
		else if imageExtensions.contains(ext) { kind = .image }
		else if ["xlsx", "xls", "numbers"].contains(ext) { throw Failure(message: "\(name): save the spreadsheet as CSV first, then attach that.") }
		else { throw Failure(message: "\(name): this kind of file can't be read. Use CSV, text, PDF, Word or an image.") }

		let id = UUID().uuidString
		let target = folder(id)
		try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
		try FileManager.default.copyItem(at: url, to: target.appendingPathComponent(name))
		var attachment = ChatAttachment(id: id, name: name, kind: kind, summary: "")
		do { attachment.summary = try describe(attachment, bytes: size) } catch {
			remove(attachment)
			throw error
		}
		return attachment
	}

	static func remove(_ attachment: ChatAttachment) {
		try? FileManager.default.removeItem(at: folder(attachment.id))
	}

	private static func describe(_ attachment: ChatAttachment, bytes: Int) throws -> String {
		let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
		switch attachment.kind {
		case .table:
			let table = try loadTable(attachment)
			return "table, \(table.rows.count) rows, columns: \(table.header.joined(separator: ", ")) (\(size))"
		case .text: return "text file (\(size))"
		case .pdf:
			let pages = PDFDocument(url: stored(attachment))?.pageCount ?? 0
			return "PDF, \(pages) page\(pages == 1 ? "" : "s") (\(size))"
		case .document: return "document (\(size))"
		case .image: return "image (\(size))"
		}
	}

	// MARK: Reading

	/// What `read_file` returns for one file: a page of rows for a table, a page of characters for
	/// anything else. `query` keeps only the table rows that contain it.
	static func read(_ attachment: ChatAttachment, query: String?, offset: Int, limit: Int?) throws -> [String: Any] {
		switch attachment.kind {
		case .table:
			let table = try loadTable(attachment)
			let needle = query?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
			let matching = needle.isEmpty ? table.rows : table.rows.filter { $0.contains { $0.lowercased().contains(needle) } }
			let count = min(max(limit ?? 50, 1), 200)
			let start = min(max(offset, 0), matching.count)
			let page = matching[start..<min(start + count, matching.count)]
			let rows = page.map { row -> [String: String] in
				var item: [String: String] = [:]
				for (index, column) in table.header.enumerated() where index < row.count { item[column] = String(row[index].prefix(300)) }
				return item
			}
			return ["file": attachment.name, "columns": table.header, "totalRows": table.rows.count, "matchedRows": matching.count,
					"offset": start, "rows": rows, "hasMore": start + rows.count < matching.count]
		case .image:
			return ["file": attachment.name, "note": "This is an image. If you can see it, it is in the user's message; you cannot read it with this tool."]
		case .text, .pdf, .document:
			let text = try plainText(attachment)
			let count = min(max(limit ?? 8_000, 500), 20_000)
			let start = min(max(offset, 0), text.count)
			let end = min(start + count, text.count)
			let slice = String(text[text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)])
			return ["file": attachment.name, "totalCharacters": text.count, "offset": start, "text": slice, "hasMore": end < text.count]
		}
	}

	private static func plainText(_ attachment: ChatAttachment) throws -> String {
		let url = stored(attachment)
		switch attachment.kind {
		case .pdf:
			guard let text = PDFDocument(url: url)?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				throw Failure(message: "No text in this PDF; it may be a scan.")
			}
			return text
		case .document:
			let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
			return attributed.string
		default:
			guard let data = try? Data(contentsOf: url) else { throw Failure(message: "The file could not be read.") }
			return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
		}
	}

	// MARK: Tables

	private struct Table { var header: [String]; var rows: [[String]] }

	private static func loadTable(_ attachment: ChatAttachment) throws -> Table {
		guard let data = try? Data(contentsOf: stored(attachment)) else { throw Failure(message: "The file could not be read.") }
		let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
		let records = parseDelimited(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
		guard let header = records.first else { throw Failure(message: "The file is empty.") }
		return Table(header: header.map { $0.trimmingCharacters(in: .whitespaces) }, rows: Array(records.dropFirst()))
	}

	/// Comma, semicolon or tab separated, with quoted cells (and quotes doubled inside them).
	static func parseDelimited(_ text: String) -> [[String]] {
		let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
		let candidates: [Character] = [",", ";", "\t"]
		let delimiter = candidates.max { a, b in firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count } ?? ","
		var records: [[String]] = []
		var row: [String] = []
		var cell = ""
		var quoted = false
		var chars = text.makeIterator()
		var pending: Character?
		func next() -> Character? { if let p = pending { pending = nil; return p }; return chars.next() }
		while let c = next() {
			if quoted {
				if c == "\"" {
					if let n = next() { if n == "\"" { cell.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
				} else { cell.append(c) }
			} else if c == "\"" {
				quoted = true
			} else if c == delimiter {
				row.append(cell); cell = ""
			} else if c == "\n" || c == "\r\n" || c == "\r" {
				row.append(cell); cell = ""
				if !(row.count == 1 && row[0].isEmpty) { records.append(row) }
				row = []
			} else { cell.append(c) }
		}
		if !cell.isEmpty || !row.isEmpty { row.append(cell); records.append(row) }
		return records
	}

	// MARK: Images

	/// An image as a data URL for a model that can see, scaled down so it stays small in the history.
	static func imageDataURL(_ attachment: ChatAttachment) -> String? {
		guard attachment.kind == .image, let image = NSImage(contentsOf: stored(attachment)),
			  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
		let longest = CGFloat(max(cg.width, cg.height))
		let scale = min(1, 1_280 / longest)
		let width = Int(CGFloat(cg.width) * scale), height = Int(CGFloat(cg.height) * scale)
		guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
									  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
		context.setFillColor(NSColor.white.cgColor)
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		context.interpolationQuality = .high
		context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
		guard let scaled = context.makeImage() else { return nil }
		let rep = NSBitmapImageRep(cgImage: scaled)
		guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
		return "data:image/jpeg;base64," + jpeg.base64EncodedString()
	}
}
