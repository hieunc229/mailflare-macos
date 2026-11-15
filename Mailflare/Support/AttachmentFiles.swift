import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers
import MailflareCore

/// Turns dropped or picked files into outgoing attachments.
enum AttachmentFiles {
	static let limit = 10 * 1024 * 1024

	/// Skips folders, repeats of `existing` and anything over the upload limit; `error` names the last one skipped.
	static func make(from urls: [URL], existing: [OutgoingAttachment]) -> (attachments: [OutgoingAttachment], error: String?) {
		var made: [OutgoingAttachment] = []
		var error: String?
		for url in urls {
			let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
			if values?.isDirectory == true { error = "\(url.lastPathComponent) is a folder. Compress it first."; continue }
			if (existing + made).contains(where: { $0.filePath == url.path }) { continue }
			let size = values?.fileSize ?? 0
			if size > limit { error = "\(url.lastPathComponent) is over the 10 MB upload limit."; continue }
			let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
			made.append(OutgoingAttachment(filePath: url.path, blobId: nil, name: url.lastPathComponent, mimeType: type, size: UInt64(size)))
		}
		return (made, error)
	}

	// MARK: Screenshots and clipboard images

	/// Files on a pasteboard (a drag or the clipboard), without folders' contents.
	static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
		(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).map(stabilized)
	}

	static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
		pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
	}

	/// A drag carries something to attach: files, or a picture with no file behind it (a fresh screenshot).
	static func canAttach(from pasteboard: NSPasteboard) -> Bool {
		pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) || hasImage(pasteboard)
	}

	/// Pasting attaches copied files, or a picture that came with no text. A picture copied with its text
	/// (from a web page or a document) keeps pasting as text.
	static func shouldAttachPaste(_ pasteboard: NSPasteboard) -> Bool {
		if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
		return hasImage(pasteboard) && pasteboard.string(forType: .string) == nil
	}

	/// The files on a pasteboard, or the picture saved as a PNG when it has no file.
	static func urls(from pasteboard: NSPasteboard) -> [URL] {
		let files = fileURLs(in: pasteboard)
		if !files.isEmpty { return files }
		guard let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
			  let tiff = image.tiffRepresentation, let url = writePNG(tiff) else { return [] }
		return [url]
	}

	/// A screenshot's thumbnail is dragged as a file in a temporary folder that disappears once it is
	/// saved or dismissed, so those are copied somewhere that stays until the message is sent.
	static func stabilized(_ url: URL) -> URL {
		guard url.path.contains("TemporaryItems") else { return url }
		let dir = scratchDirectory()
		let copy = dir.appendingPathComponent(url.lastPathComponent)
		do { try FileManager.default.copyItem(at: url, to: copy); return copy } catch { return url }
	}

	/// Saves picture data as a PNG named like a macOS screenshot.
	static func writePNG(_ data: Data) -> URL? {
		guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return nil }
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
		let url = scratchDirectory().appendingPathComponent("Screenshot \(formatter.string(from: Date())).png")
		do { try png.write(to: url); return url } catch { return nil }
	}

	private static func scratchDirectory() -> URL {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mailflare-pasted/\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	/// What a SwiftUI drop carries: files, or picture data that has no file.
	static func load(_ providers: [NSItemProvider]) async -> [URL] {
		var out: [URL] = []
		for provider in providers {
			if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
				let url: URL? = await withCheckedContinuation { c in
					provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
						if let data = item as? Data { c.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
						else if let url = item as? URL { c.resume(returning: url) }
						else { c.resume(returning: nil) }
					}
				}
				if let url { out.append(stabilized(url)); continue }
			}
			if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
				let data: Data? = await withCheckedContinuation { c in
					provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in c.resume(returning: data) }
				}
				if let data, let url = writePNG(data) { out.append(url) }
			}
		}
		return out
	}
}

extension View {
	/// Accepts files and pictures (a fresh screenshot is a picture with no file yet) as attachments.
	func attachmentDrop(enabled: Bool = true, isTargeted: Binding<Bool> = .constant(false), perform: @escaping ([URL]) -> Void) -> some View {
		onDrop(of: [.fileURL, .image], isTargeted: isTargeted) { providers in
			guard enabled else { return false }
			Task { @MainActor in perform(await AttachmentFiles.load(providers)) }
			return true
		}
	}
}
