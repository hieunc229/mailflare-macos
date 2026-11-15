import SwiftUI
import WebKit

/// Which formats apply at the caret, for the toolbar's pressed buttons.
struct ComposerFormats: Equatable {
	var bold = false, italic = false, underline = false, strike = false
	var bulletList = false, numberList = false, quote = false
}

/// The composer's handle on its web view: toolbar commands go in, caret formats come out.
@MainActor
@Observable
final class ComposerController {
	private(set) var formats = ComposerFormats()
	/// Set when ⌘K is pressed in the editor; the toolbar opens its link field and clears it.
	var linkRequested = false
	private(set) var canUndo = false
	private(set) var canRedo = false
	@ObservationIgnored fileprivate weak var webView: WKWebView?

	func bold() { run("bold") }
	func italic() { run("italic") }
	func underline() { run("underline") }
	func strikethrough() { run("strikeThrough") }
	func bulletList() { run("insertUnorderedList") }
	func numberList() { run("insertOrderedList") }
	func undo() { run("undo") }
	func redo() { run("redo") }
	func quote() { script("__mf.quote()") }
	func clearFormatting() { script("__mf.clear()") }
	func focus() { script("__mf.focus()") }
	func rememberSelection() { script("__mf.remember()") }

	/// Links the selection, or inserts the address itself when nothing is selected.
	func insertLink(_ raw: String) {
		let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return }
		let url = text.range(of: #"^(https?:|mailto:)"#, options: [.regularExpression, .caseInsensitive]) != nil ? text : "https://\(text)"
		script("__mf.link(\(Self.literal(url)))")
	}

	/// Inserts HTML at the caret, or at the end when the editor was never focused.
	func insert(html: String) { script("__mf.insert(\(Self.literal(ComposerEditor.sanitize(html))))") }

	/// Replaces the whole body as one undoable edit, for the AI writer.
	func replaceAll(html: String) { script("__mf.replaceAll(\(Self.literal(ComposerEditor.sanitize(html))))") }

	private func run(_ command: String) { script("__mf.run(\(Self.literal(command)))") }

	private func script(_ source: String) {
		webView?.evaluateJavaScript(source, in: nil, in: .defaultClient) { _ in }
	}

	fileprivate func applyHistory(_ state: [String: Any]) {
		canUndo = state["undo"] as? Bool ?? false
		canRedo = state["redo"] as? Bool ?? false
	}

	fileprivate func apply(_ state: [String: Any]) {
		func flag(_ key: String) -> Bool { state[key] as? Bool ?? false }
		formats = ComposerFormats(
			bold: flag("bold"), italic: flag("italic"), underline: flag("underline"), strike: flag("strike"),
			bulletList: flag("ul"), numberList: flag("ol"), quote: flag("quote"))
	}

	/// A string as a JavaScript literal.
	private static func literal(_ value: String) -> String {
		guard let data = try? JSONSerialization.data(withJSONObject: [value]), let text = String(data: data, encoding: .utf8) else { return "\"\"" }
		return String(text.dropFirst().dropLast())
	}
}

/// A rich-text message body: an editable page that the toolbar drives with `execCommand`, as the web
/// composer does. The page's own JavaScript stays off; the app's script runs in its own world and
/// reports the HTML back on every edit.
struct ComposerEditor: NSViewRepresentable {
	let initialHTML: String
	let controller: ComposerController
	var placeholder = "Write your message…"
	/// Sized by its text instead of filling its frame: it reports its height (`onHeight`) and scrolls
	/// on its own once the frame it is given is shorter. For the reader's reply box.
	var fitsContent = false
	/// Takes the keyboard once loaded, with the caret after the text.
	var autofocus = false
	var onChange: (String) -> Void
	/// Files dropped on the editor; they become attachments rather than page content.
	var onFiles: ([URL]) -> Void = { _ in }
	/// The text's height in points, when `fitsContent`.
	var onHeight: (CGFloat) -> Void = { _ in }
	/// The page has loaded (and, with `autofocus`, taken the keyboard).
	var onReady: () -> Void = {}
	/// Escape was pressed in the editor.
	var onEscape: () -> Void = {}

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.defaultWebpagePreferences.allowsContentJavaScript = false
		config.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
		config.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "composer")
		let view = ComposerWebView(frame: .zero, configuration: config)
		view.navigationDelegate = context.coordinator
		view.setValue(false, forKey: "drawsBackground")
		view.onFiles = { [coordinator = context.coordinator] urls in coordinator.parent.onFiles(urls) }
		controller.webView = view
		view.loadHTMLString(Self.document(body: initialHTML, placeholder: placeholder, fitsContent: fitsContent), baseURL: nil)
		return view
	}

	func updateNSView(_ view: WKWebView, context: Context) {
		context.coordinator.parent = self
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
		var parent: ComposerEditor
		init(_ parent: ComposerEditor) { self.parent = parent }

		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			if parent.autofocus {
				webView.window?.makeFirstResponder(webView)
				webView.evaluateJavaScript("__mf.focusEnd()", in: nil, in: .defaultClient) { _ in }
			}
			parent.onReady()
		}

		/// Links in the editor are text being written, never somewhere to go.
		func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
			action.navigationType == .other ? .allow : .cancel
		}

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let payload = message.body as? [String: Any], let name = payload["name"] as? String else { return }
			DispatchQueue.main.async { [self] in
				switch name {
				case "html": parent.onChange(payload["body"] as? String ?? "")
				case "state": parent.controller.apply(payload["body"] as? [String: Any] ?? [:])
				case "history": parent.controller.applyHistory(payload["body"] as? [String: Any] ?? [:])
				case "link": parent.controller.linkRequested = true
				case "height": (payload["body"] as? NSNumber).map { parent.onHeight(CGFloat($0.doubleValue)) }
				case "escape": parent.onEscape()
				default: break
				}
			}
		}
	}

	/// A web view that hands dropped files to the composer instead of letting the page take them.
	final class ComposerWebView: WKWebView {
		var onFiles: ([URL]) -> Void = { _ in }

		private func hasFiles(_ info: NSDraggingInfo) -> Bool { AttachmentFiles.canAttach(from: info.draggingPasteboard) }

		override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { hasFiles(sender) ? .copy : super.draggingEntered(sender) }
		override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { hasFiles(sender) ? .copy : super.draggingUpdated(sender) }
		override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hasFiles(sender) ? true : super.prepareForDragOperation(sender) }
		override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
			guard hasFiles(sender) else { return super.performDragOperation(sender) }
			let urls = AttachmentFiles.urls(from: sender.draggingPasteboard)
			guard !urls.isEmpty else { return super.performDragOperation(sender) }
			onFiles(urls)
			return true
		}

		/// Cmd-V with files or a picture on the clipboard attaches them instead of pasting.
		override func performKeyEquivalent(with event: NSEvent) -> Bool {
			let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
			if flags == .command, event.charactersIgnoringModifiers == "v", AttachmentFiles.shouldAttachPaste(.general) {
				let urls = AttachmentFiles.urls(from: .general)
				if !urls.isEmpty { onFiles(urls); return true }
			}
			return super.performKeyEquivalent(with: event)
		}
	}

	// MARK: Page

	/// Drops what could run or phone home from HTML that did not come from the editor itself.
	static func sanitize(_ html: String) -> String {
		var out = html
		let patterns = [
			#"<(script|iframe|object|embed|style|link|meta|form)\b[^>]*>.*?</\1\s*>"#,
			#"<(script|iframe|object|embed|style|link|meta|form|input)\b[^>]*/?>"#,
			#"\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
			#"(href|src)\s*=\s*("\s*javascript:[^"]*"|'\s*javascript:[^']*')"#,
		]
		for pattern in patterns {
			out = out.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
		}
		return out
	}

	private static func document(body: String, placeholder: String, fitsContent: Bool) -> String {
		// Fitting: the text sets its own height and the page scrolls when the frame is shorter.
		let fit = fitsContent ? "body{overflow-y:auto}#ed{min-height:0;padding:0}" : ""
		let hint = placeholder.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
		return """
		<!doctype html><html><head><meta charset="utf-8">
		<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
		<meta name="color-scheme" content="light dark">
		<style>
		html,body{margin:0;background:transparent;height:100%}
		body{font:14px/1.45 -apple-system,system-ui}
		#ed{min-height:100%;box-sizing:border-box;padding:10px 14px;outline:none;word-wrap:break-word;display:flow-root}
		#ed p{margin:0 0 .6em}#ed p:last-child{margin-bottom:0}
		#ed:empty::before{content:attr(data-placeholder);color:#8e8e93;pointer-events:none}
		blockquote{margin:0 0 0 2px;padding-left:12px;border-left:3px solid rgba(128,128,128,.45);color:inherit;opacity:.85}
		a{color:#0a84ff}img{max-width:100%;height:auto}pre{font-family:inherit}\(fit)
		</style></head><body><div id="ed" contenteditable="true" spellcheck="true" data-placeholder="\(hint)">\(sanitize(body))</div></body></html>
		"""
	}

	private static let script = #"""
	(() => {
		const ed = document.getElementById("ed");
		if (!ed) return;
		const post = (name, body) => window.webkit.messageHandlers.composer.postMessage({ name, body });
		const html = () => (ed.innerText.trim() === "" && !ed.querySelector("img")) ? "" : ed.innerHTML;
		const history = () => {
			const can = c => { try { return document.queryCommandEnabled(c); } catch (e) { return false; } };
			post("history", { undo: can("undo"), redo: can("redo") });
		};
		const emit = () => { post("html", html()); history(); };
		const state = () => {
			if (document.activeElement !== ed) return;
			const q = c => { try { return document.queryCommandState(c); } catch (e) { return false; } };
			let quote = false;
			try { quote = document.queryCommandValue("formatBlock").toLowerCase() === "blockquote"; } catch (e) {}
			post("state", { bold: q("bold"), italic: q("italic"), underline: q("underline"), strike: q("strikeThrough"),
				ul: q("insertUnorderedList"), ol: q("insertOrderedList"), quote });
		};
		let saved = null;
		const restore = () => {
			ed.focus();
			const s = window.getSelection();
			if (saved && s) { s.removeAllRanges(); s.addRange(saved); }
		};
		const esc = s => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
		ed.addEventListener("input", () => { emit(); state(); post("height", height()); });
		const height = () => Math.ceil(Math.max(ed.getBoundingClientRect().height, ed.scrollHeight));
		if (window.ResizeObserver) new ResizeObserver(() => post("height", height())).observe(ed);
		document.addEventListener("selectionchange", state);
		ed.addEventListener("paste", e => {
			e.preventDefault();
			document.execCommand("insertText", false, e.clipboardData.getData("text/plain"));
		});
		ed.addEventListener("keydown", e => {
			const k = e.key.toLowerCase();
			if (e.metaKey && !e.shiftKey && !e.altKey && (k === "b" || k === "i" || k === "u")) {
				e.preventDefault();
				window.__mf.run(k === "b" ? "bold" : k === "i" ? "italic" : "underline");
				return;
			}
			if (e.key === "Escape") { post("escape", ""); return; }
			if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); saved = getSelection().rangeCount ? getSelection().getRangeAt(0).cloneRange() : null; post("link", ""); }
		});
		window.__mf = {
			run(cmd) { ed.focus(); document.execCommand(cmd, false, null); emit(); state(); },
			quote() {
				ed.focus();
				let on = false;
				try { on = document.queryCommandValue("formatBlock").toLowerCase() === "blockquote"; } catch (e) {}
				document.execCommand("formatBlock", false, on ? "div" : "blockquote");
				emit(); state();
			},
			clear() { ed.focus(); document.execCommand("removeFormat"); document.execCommand("unlink"); emit(); state(); },
			focus() { ed.focus(); },
			focusEnd() {
				ed.focus();
				const r = document.createRange(); r.selectNodeContents(ed); r.collapse(false);
				const s = getSelection(); s.removeAllRanges(); s.addRange(r);
				post("height", height());
			},
			replaceAll(markup) {
				ed.focus();
				const r = document.createRange(); r.selectNodeContents(ed);
				const s = getSelection(); s.removeAllRanges(); s.addRange(r);
				if (markup === "") document.execCommand("delete"); else document.execCommand("insertHTML", false, markup);
				emit(); state();
				// The new text may be taller or shorter; say so now and once layout has settled.
				post("height", height());
				requestAnimationFrame(() => post("height", height()));
			},
			remember() { const s = getSelection(); saved = s.rangeCount && ed.contains(s.anchorNode) ? s.getRangeAt(0).cloneRange() : null; },
			link(url) {
				restore();
				const s = getSelection();
				if (s && s.isCollapsed) document.execCommand("insertHTML", false, `<a href="${esc(url)}">${esc(url)}</a>`);
				else document.execCommand("createLink", false, url);
				emit(); state();
			},
			insert(markup) {
				if (document.activeElement !== ed) {
					ed.focus();
					const r = document.createRange(); r.selectNodeContents(ed); r.collapse(false);
					const s = getSelection(); s.removeAllRanges(); s.addRange(r);
				}
				document.execCommand("insertHTML", false, markup);
				emit();
			},
		};
	})();
	"""#
}
