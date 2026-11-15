import SwiftUI
import Vision
import NaturalLanguage
import MailflareCore

/// An image being edited in the full-window editor, and what to do with the result.
struct ImageEditSession: Identifiable {
	let id = UUID()
	let url: URL
	let name: String
	let onSave: (URL) -> Void
}

enum SensitiveKind: String, CaseIterable, Identifiable {
	case email, phone, address, name, link, number
	var id: String { rawValue }
	var title: String {
		switch self {
		case .email: "Email addresses"
		case .phone: "Phone numbers"
		case .address: "Street addresses"
		case .name: "Names"
		case .link: "Links"
		case .number: "Long numbers (cards, IDs)"
		}
	}
}

struct SensitiveBox: Identifiable {
	let id = UUID()
	let rect: CGRect
	let kind: SensitiveKind
}

enum RedactionStyle: String, CaseIterable, Identifiable {
	case blur = "Blur", box = "Black box"
	var id: String { rawValue }
}

enum EditorTool { case crop, arrow, text }

enum MarkColor: String, CaseIterable, Identifiable {
	case red, orange, yellow, green, blue, black, white
	var id: String { rawValue }
	var color: Color {
		switch self {
		case .red: .red
		case .orange: .orange
		case .yellow: .yellow
		case .green: .green
		case .blue: .blue
		case .black: .black
		case .white: .white
		}
	}
}

enum MarkAlign: String, CaseIterable, Identifiable {
	case left, center, right
	var id: String { rawValue }
	var alignment: TextAlignment { switch self { case .left: .leading; case .center: .center; case .right: .trailing } }
	var symbol: String { "text.align\(rawValue)" }
	var frameAlignment: Alignment { switch self { case .left: .leading; case .center: .center; case .right: .trailing } }
}

struct ArrowMark: Identifiable { let id = UUID(); var from: CGPoint; var to: CGPoint }

struct TextMark: Identifiable {
	static let families = ["System", "Helvetica Neue", "Avenir Next", "Georgia", "Times New Roman", "Courier New", "Marker Felt"]

	let id = UUID()
	var at: CGPoint
	var text: String
	/// The sizes word processors offer.
	static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72, 96]

	var size: CGFloat = 16
	var color: MarkColor = .red
	var family = "System"
	var bold = false
	var italic = false
	var underline = false
	var align: MarkAlign = .center
	/// Set once the box is resized: the text wraps inside it. Nil sizes the box to the text.
	var width: CGFloat?

	func font(unit: CGFloat) -> Font {
		let base: Font = family == "System"
			? .system(size: size * unit, weight: bold ? .bold : .regular)
			: .custom(family, size: size * unit).weight(bold ? .bold : .regular)
		return italic ? base.italic() : base
	}

	/// Used to measure the text for hit testing and the selection frame.
	func nsFont(unit: CGFloat) -> NSFont {
		let points = size * unit
		var font: NSFont = family == "System"
			? .systemFont(ofSize: points, weight: bold ? .bold : .regular)
			: (NSFontManager.shared.font(withFamily: family, traits: [], weight: bold ? 9 : 5, size: points) ?? .systemFont(ofSize: points, weight: bold ? .bold : .regular))
		if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
		return font
	}

	/// The text's box in image pixels; `at` is its centre.
	func bounds(unit: CGFloat) -> CGRect {
		let attributes: [NSAttributedString.Key: Any] = [.font: nsFont(unit: unit)]
		let text = text.isEmpty ? " " : text
		let measured: CGSize
		if let width {
			let box = (text as NSString).boundingRect(
				with: CGSize(width: width, height: .greatestFiniteMagnitude),
				options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
			measured = CGSize(width: width, height: ceil(box.height))
		} else {
			measured = (text as NSString).size(withAttributes: attributes)
		}
		return CGRect(x: at.x - measured.width / 2, y: at.y - measured.height / 2, width: measured.width, height: measured.height)
	}
}

/// What a click landed on.
struct MarkHit { let id: UUID; let isText: Bool }

/// The editor's state. Points and rects are in image pixels, origin top-left.
@MainActor @Observable
final class ImageEditorModel {
	struct Snapshot { var base: CGImage; var arrows: [ArrowMark]; var texts: [TextMark] }

	var base: CGImage
	var arrows: [ArrowMark] = [] { didSet { revision &+= 1 } }
	var texts: [TextMark] = [] { didSet { revision &+= 1 } }
	/// Bumps on every change to a mark, so the picture redraws even when an array is edited in place.
	var revision = 0
	var tool: EditorTool = .arrow
	var selected: UUID?
	/// The look a new text starts with; changing a text's style updates it too.
	var textStyle = TextMark(at: .zero, text: "")
	var redact = false
	var style: RedactionStyle = .blur
	var kinds: Set<SensitiveKind> = [.email, .phone, .address, .name]
	var detected: [SensitiveBox] = []
	var detecting = false
	private var history: [Snapshot] = []
	private var detection: Task<Void, Never>?

	init?(url: URL) {
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
			  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
		else { return nil }
		base = image
	}

	var size: CGSize { CGSize(width: base.width, height: base.height) }
	var unit: CGFloat { max(1, max(size.width, size.height) / 700) }
	var selectedTextIndex: Int? { texts.firstIndex { $0.id == selected } }
	var selectedArrow: ArrowMark? { arrows.first { $0.id == selected } }

	/// The topmost text or arrow under a point in image pixels.
	func hit(at point: CGPoint) -> MarkHit? {
		for mark in texts.reversed() where mark.bounds(unit: unit).insetBy(dx: -8 * unit, dy: -6 * unit).contains(point) {
			return MarkHit(id: mark.id, isText: true)
		}
		for arrow in arrows.reversed() where Self.distance(from: point, toSegment: arrow.from, arrow.to) <= 12 * unit {
			return MarkHit(id: arrow.id, isText: false)
		}
		return nil
	}

	private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
		let dx = b.x - a.x, dy = b.y - a.y
		let lengthSquared = dx * dx + dy * dy
		guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
		let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
		return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
	}

	func deleteSelected() {
		guard selected != nil else { return }
		push()
		arrows.removeAll { $0.id == selected }
		texts.removeAll { $0.id == selected }
		selected = nil
	}
	var canUndo: Bool { !history.isEmpty }
	var redactions: [CGRect] { redact ? detected.filter { kinds.contains($0.kind) }.map(\.rect) : [] }

	func count(_ kind: SensitiveKind) -> Int { detected.filter { $0.kind == kind }.count }

	func push() { history.append(Snapshot(base: base, arrows: arrows, texts: texts)) }

	func undo() {
		guard let last = history.popLast() else { return }
		let changed = last.base !== base
		base = last.base; arrows = last.arrows; texts = last.texts
		if changed { detect() }
	}

	func crop(to rect: CGRect) {
		let bounds = CGRect(origin: .zero, size: size)
		let r = rect.intersection(bounds).integral
		guard r.width >= 8, r.height >= 8, let cropped = base.cropping(to: r) else { return }
		push()
		base = cropped
		let shift = CGPoint(x: -r.minX, y: -r.minY)
		arrows = arrows.map { var m = $0; m.from = m.from.offset(shift); m.to = m.to.offset(shift); return m }
		texts = texts.map { var m = $0; m.at = m.at.offset(shift); return m }
		detect()
	}

	/// Finds text that looks sensitive. Runs when the redact switch is first used and after a crop.
	func detect() {
		detection?.cancel()
		guard redact else { detected = []; return }
		let image = base
		detecting = true
		detection = Task { [weak self] in
			let found = await Task.detached(priority: .userInitiated) { Self.findSensitive(in: image) }.value
			guard !Task.isCancelled, let self else { return }
			detected = found
			detecting = false
		}
	}

	nonisolated static func findSensitive(in image: CGImage) -> [SensitiveBox] {
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		request.usesLanguageCorrection = false
		try? VNImageRequestHandler(cgImage: image).perform([request])
		let w = CGFloat(image.width), h = CGFloat(image.height)
		var out: [SensitiveBox] = []
		let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType([.link, .phoneNumber, .address]).rawValue)
		let digits = try? NSRegularExpression(pattern: #"\d[\d .-]{6,}\d"#)

		for observation in request.results ?? [] {
			guard let line = observation.topCandidates(1).first else { continue }
			let text = line.string
			let whole = NSRange(text.startIndex..., in: text)
			func add(_ range: Range<String.Index>, _ kind: SensitiveKind) {
				guard let box = try? line.boundingBox(for: range) else { return }
				let b = box.boundingBox
				let rect = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h).insetBy(dx: -3, dy: -3)
				out.append(SensitiveBox(rect: rect, kind: kind))
			}
			var taken: [NSRange] = []
			for match in detector?.matches(in: text, range: whole) ?? [] {
				guard let range = Range(match.range, in: text) else { continue }
				taken.append(match.range)
				switch match.resultType {
				case .phoneNumber: add(range, .phone)
				case .address: add(range, .address)
				default: add(range, match.url?.scheme == "mailto" ? .email : .link)
				}
			}
			for match in digits?.matches(in: text, range: whole) ?? [] where !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
				if let range = Range(match.range, in: text) { add(range, .number) }
			}
			let tagger = NLTagger(tagSchemes: [.nameType])
			tagger.string = text
			tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
				if tag == .personalName { add(range, .name) }
				return true
			}
		}
		return out
	}

	/// The edited image as PNG, rendered at the picture's own pixel size.
	func render() -> Data? {
		let size = self.size
		let view = ComposedImageView(
			image: base, size: size, arrows: arrows, texts: texts, redactions: redactions, style: style
		).frame(width: size.width, height: size.height)
		let renderer = ImageRenderer(content: view)
		renderer.scale = 1
		guard let cg = renderer.cgImage else { return nil }
		return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
	}
}

private extension CGPoint {
	func offset(_ d: CGPoint) -> CGPoint { CGPoint(x: x + d.x, y: y + d.y) }
}

/// The picture with its marks, drawn at 1 point per pixel. Shown scaled in the editor and rendered as is on save.
struct ComposedImageView: View {
	let image: CGImage
	let size: CGSize
	let arrows: [ArrowMark]
	let texts: [TextMark]
	let redactions: [CGRect]
	let style: RedactionStyle
	var revision = 0

	private var unit: CGFloat { max(1, max(size.width, size.height) / 700) }

	var body: some View {
		ZStack(alignment: .topLeading) {
			picture
			if !redactions.isEmpty {
				switch style {
				case .blur:
					picture.blur(radius: 9 * unit, opaque: true).mask(alignment: .topLeading) { redactionShapes }
				case .box:
					redactionShapes.foregroundStyle(.black)
				}
			}
			ForEach(arrows) { arrow in
				ArrowShape(from: arrow.from, to: arrow.to, head: 16 * unit)
					.stroke(Color.red, style: StrokeStyle(lineWidth: 4 * unit, lineCap: .round, lineJoin: .round))
			}
			ForEach(texts) { mark in
				let label = Text(mark.text)
					.font(mark.font(unit: unit))
					.underline(mark.underline)
					.multilineTextAlignment(mark.align.alignment)
					.foregroundStyle(mark.color.color)
				if let width = mark.width {
					label.frame(width: width, alignment: mark.align.frameAlignment)
						.fixedSize(horizontal: false, vertical: true)
						.position(x: mark.at.x, y: mark.at.y)
				} else {
					label.fixedSize().position(x: mark.at.x, y: mark.at.y)
				}
			}
		}
		.frame(width: size.width, height: size.height, alignment: .topLeading)
		.clipped()
	}

	private var picture: some View {
		Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
	}

	private var redactionShapes: some View {
		ZStack(alignment: .topLeading) {
			ForEach(Array(redactions.enumerated()), id: \.offset) { _, r in
				Rectangle().frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
			}
		}
		.frame(width: size.width, height: size.height, alignment: .topLeading)
	}
}

private struct ArrowShape: Shape {
	let from: CGPoint
	let to: CGPoint
	let head: CGFloat

	func path(in rect: CGRect) -> Path {
		var p = Path()
		p.move(to: from)
		p.addLine(to: to)
		let angle = atan2(to.y - from.y, to.x - from.x)
		for side in [-1.0, 1.0] {
			let a = angle + .pi - side * .pi / 7
			p.move(to: to)
			p.addLine(to: CGPoint(x: to.x + head * cos(a), y: to.y + head * sin(a)))
		}
		return p
	}
}

/// Full-window image editor: crop, arrows, text, and redaction of sensitive text found in the picture.
struct ImageEditorView: View {
	/// A text or arrow being dragged to a new place.
	private struct Move {
		let id: UUID
		let isText: Bool
		let origin: [CGPoint]
		var pushed = false
	}

	/// The left or right edge of a text box being dragged to change its width.
	private struct TextResize {
		let id: UUID
		let side: CGFloat
		let start: CGRect
		var pushed = false
	}

	let session: ImageEditSession
	var close: () -> Void

	@State private var model: ImageEditorModel?
	@State private var dragStart: CGPoint?
	@State private var dragNow: CGPoint?
	@State private var cropRect: CGRect?
	@State private var cropFrame: CropFrame = .free
	@State private var cropDrag: CropDrag?
	@State private var editOriginal = ""
	@State private var creatingID: UUID?
	@State private var moving: Move?
	@State private var resizing: TextResize?
	@State private var editingID: UUID?
	@State private var draft = ""
	@FocusState private var textFocused: Bool

	var body: some View {
		ZStack {
			Color.black.opacity(0.45).contentShape(Rectangle()).onTapGesture {}
			VStack(spacing: 0) {
				if let model {
					HStack(spacing: 0) {
						canvas(model).overlay(alignment: .topLeading) { toolbar }
						Divider()
						sidePanel(model)
					}
				} else {
					VStack {
						Text("This image can't be opened.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
						Button("Close", action: close).buttonStyle(.pill).keyboardShortcut(.cancelAction).padding(16)
					}
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(AppTheme.background)
			.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.outline, lineWidth: 1))
			.shadow(color: .black.opacity(0.35), radius: 24, y: 8)
			// Clears the traffic lights.
			.padding(.top, 44).padding(.horizontal, 20).padding(.bottom, 20)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.ignoresSafeArea()
		.onAppear { model = ImageEditorModel(url: session.url) }
	}

	// MARK: Toolbar

	private var toolbar: some View {
		HStack(spacing: 8) {
			if let model {
				iconButton("arrow.uturn.backward", "Undo", active: false) { model.undo(); cropRect = nil }
					.opacity(model.canUndo ? 1 : 0.35).disabled(!model.canUndo)
				Divider().frame(height: 22).padding(.horizontal, 4)
				toolButton(.crop, "crop", "Crop", model)
				toolButton(.arrow, "arrow.up.right", "Arrow", model)
				toolButton(.text, "textformat", "Text", model)
				Spacer(minLength: 12)
				if model.tool == .crop {
					frameButton(.square, "square", "Square (1:1)", model)
					frameButton(.portrait, "rectangle.portrait", "Portrait (3:4)", model)
					frameButton(.landscape, "rectangle", "Landscape (4:3)", model)
					if let rect = cropRect {
						Button("Apply Crop") { model.crop(to: rect); cropRect = nil }
							.buttonStyle(.pillProminent)
						Button("Reset") { cropRect = nil }.buttonStyle(.pill)
					}
				}
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity)
	}

	/// Locks the crop area to a ratio; pressing the active one frees it again.
	private func frameButton(_ frame: CropFrame, _ symbol: String, _ help: String, _ model: ImageEditorModel) -> some View {
		iconButton(symbol, help, active: cropFrame == frame) {
			cropFrame = cropFrame == frame ? .free : frame
			applyFrame(CGRect(origin: .zero, size: model.size))
		}
	}

	/// A flat icon button; `active` keeps a soft highlight behind it.
	private func iconButton(_ symbol: String, _ help: String, active: Bool, size: CGFloat = 36, action: @escaping () -> Void) -> some View {
		EditorIconButton(symbol: symbol, help: help, active: active, size: size, action: action)
	}

	private func toolButton(_ tool: EditorTool, _ symbol: String, _ help: String, _ model: ImageEditorModel) -> some View {
		iconButton(symbol, help, active: model.tool == tool) {
			model.tool = tool
			if tool != .crop { cropRect = nil }
		}
	}

	// MARK: Canvas

	private func canvas(_ model: ImageEditorModel) -> some View {
		GeometryReader { proxy in
			let size = model.size
			let scale = min(proxy.size.width / size.width, proxy.size.height / size.height, 3)
			let shown = CGSize(width: size.width * scale, height: size.height * scale)
			ZStack(alignment: .topLeading) {
				ComposedImageView(
					image: model.base, size: size, arrows: model.arrows + liveArrow(scale), texts: model.texts.filter { $0.id != editingID },
					redactions: model.redactions, style: model.style, revision: model.revision)
					.scaleEffect(scale, anchor: .topLeading)
					.frame(width: shown.width, height: shown.height, alignment: .topLeading)
				cropOverlay(shown, scale)
				selectionOverlay(model, scale)
				if let id = editingID, let i = model.texts.firstIndex(where: { $0.id == id }) {
					let mark = model.texts[i]
					let box = mark.bounds(unit: model.unit)
					TextField("Text", text: $draft, axis: .vertical)
						.textFieldStyle(.plain)
						.font(mark.font(unit: model.unit * scale))
						.foregroundStyle(mark.color.color)
						.multilineTextAlignment(mark.align.alignment)
						.frame(width: mark.width.map { $0 * scale } ?? max(box.width * scale + 16, 80), alignment: mark.align.frameAlignment)
						.focused($textFocused)
						.onSubmit { commitEdit(model) }
						.onChange(of: draft) { _, new in
							if let j = model.texts.firstIndex(where: { $0.id == id }) { model.texts[j].text = new }
						}
						.position(x: mark.at.x * scale, y: box.midY * scale)
				}
			}
			.frame(width: shown.width, height: shown.height)
			.contentShape(Rectangle())
			.gesture(drag(model, scale))
			.simultaneousGesture(SpatialTapGesture(count: 2).onEnded { startEditing(model, at: $0.location, scale) })
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.padding(.top, 60).padding(.horizontal, 24).padding(.bottom, 24)
	}

	/// A frame around the selected text, or handles on the selected arrow's ends.
	@ViewBuilder
	private func selectionOverlay(_ model: ImageEditorModel, _ scale: CGFloat) -> some View {
		if let i = model.selectedTextIndex {
			let r = model.texts[i].bounds(unit: model.unit).insetBy(dx: -6 * model.unit, dy: -4 * model.unit)
			ZStack(alignment: .topLeading) {
				RoundedRectangle(cornerRadius: 3)
					.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
					.frame(width: r.width * scale, height: r.height * scale)
					.offset(x: r.minX * scale, y: r.minY * scale)
				ForEach([r.minX, r.maxX], id: \.self) { x in
					RoundedRectangle(cornerRadius: 2).fill(Color.white).overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 1.5))
						.frame(width: 8, height: 16)
						.offset(x: x * scale - 4, y: r.midY * scale - 8)
				}
			}
			.allowsHitTesting(false)
		} else if let arrow = model.selectedArrow {
			ZStack(alignment: .topLeading) {
				ForEach(Array([arrow.from, arrow.to].enumerated()), id: \.offset) { _, p in
					Circle().fill(Color.white).overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
						.frame(width: 10, height: 10)
						.offset(x: p.x * scale - 5, y: p.y * scale - 5)
				}
			}
			.allowsHitTesting(false)
		}
	}

	/// The arrow being dragged, shown before it is committed.
	private func liveArrow(_ scale: CGFloat) -> [ArrowMark] {
		guard model?.tool == .arrow, moving == nil, let a = dragStart, let b = dragNow else { return [] }
		return [ArrowMark(from: CGPoint(x: a.x / scale, y: a.y / scale), to: CGPoint(x: b.x / scale, y: b.y / scale))]
	}

	@ViewBuilder
	private func cropOverlay(_ shown: CGSize, _ scale: CGFloat) -> some View {
		if let c = cropRect {
			let rect = CGRect(x: c.minX * scale, y: c.minY * scale, width: c.width * scale, height: c.height * scale)
			let points = [
				CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
				CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
				CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
			]
			ZStack(alignment: .topLeading) {
				Color.black.opacity(0.45)
					.mask(alignment: .topLeading) {
						Rectangle().overlay(alignment: .topLeading) {
							Rectangle().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY).blendMode(.destinationOut)
						}.compositingGroup()
					}
				Rectangle().stroke(Color.white, lineWidth: 1.5).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
				ForEach(Array(points.enumerated()), id: \.offset) { _, p in
					Rectangle().fill(Color.white).overlay(Rectangle().stroke(Color.black.opacity(0.5), lineWidth: 1))
						.frame(width: 9, height: 9).offset(x: p.x - 4.5, y: p.y - 4.5)
				}
			}
			.frame(width: shown.width, height: shown.height, alignment: .topLeading)
			.allowsHitTesting(false)
		}
	}

	private func cropChanged(_ model: ImageEditorModel, _ value: DragGesture.Value, _ scale: CGFloat) {
		let bounds = CGRect(origin: .zero, size: model.size)
		let here = imagePoint(value.location, scale)
		if cropDrag == nil {
			let start = imagePoint(value.startLocation, scale)
			if let r = cropRect {
				let handle = CropMath.handle(at: start, in: r, tolerance: 10 / scale)
				cropDrag = CropDrag(handle: handle, start: handle == .create ? .zero : r, origin: start)
			} else {
				cropDrag = CropDrag(handle: .create, start: .zero, origin: start)
			}
		}
		guard let drag = cropDrag else { return }
		let shift = NSEvent.modifierFlags.contains(.shift)
		let held = drag.start.height > 0 ? drag.start.width / drag.start.height : nil
		let ratio = cropFrame.ratio ?? (shift ? held : nil)
		switch drag.handle {
		case .move:
			var r = drag.start.offsetBy(dx: here.x - drag.origin.x, dy: here.y - drag.origin.y)
			r.origin.x = max(0, min(r.minX, bounds.width - r.width))
			r.origin.y = max(0, min(r.minY, bounds.height - r.height))
			cropRect = r
		case .create:
			cropRect = CropMath.anchored(anchor: drag.origin.clamped(to: bounds), to: here, ratio: ratio, bounds: bounds)
		case .edge(let h, let v):
			if h != 0 && v != 0 {
				let anchor = CGPoint(x: h < 0 ? drag.start.maxX : drag.start.minX, y: v < 0 ? drag.start.maxY : drag.start.minY)
				cropRect = CropMath.anchored(anchor: anchor, to: here, ratio: ratio, bounds: bounds)
			} else {
				cropRect = CropMath.edge(start: drag.start, h: h, v: v, to: here, ratio: ratio, bounds: bounds)
			}
		}
	}

	private func drag(_ model: ImageEditorModel, _ scale: CGFloat) -> some Gesture {
		DragGesture(minimumDistance: 0)
			.onChanged { value in
				if model.tool == .crop { cropChanged(model, value, scale); return }
				if resizing == nil, moving == nil, dragStart == nil, let i = model.selectedTextIndex {
					let p = imagePoint(value.startLocation, scale)
					let frame = model.texts[i].bounds(unit: model.unit).insetBy(dx: -6 * model.unit, dy: -4 * model.unit)
					let tolerance = 10 / scale
					if p.y >= frame.minY, p.y <= frame.maxY {
						if abs(p.x - frame.minX) <= tolerance { resizing = TextResize(id: model.texts[i].id, side: -1, start: model.texts[i].bounds(unit: model.unit)) }
						else if abs(p.x - frame.maxX) <= tolerance { resizing = TextResize(id: model.texts[i].id, side: 1, start: model.texts[i].bounds(unit: model.unit)) }
					}
				}
				if var resize = resizing {
					let dx = value.translation.width / scale
					guard let i = model.texts.firstIndex(where: { $0.id == resize.id }), abs(dx) > 1 || resize.pushed else { return }
					if !resize.pushed { model.push(); resize.pushed = true; resizing = resize }
					let width = max(20 * model.unit, resize.side > 0 ? resize.start.width + dx : resize.start.width - dx)
					let left = resize.side > 0 ? resize.start.minX : resize.start.maxX - width
					model.texts[i].width = width
					let height = model.texts[i].bounds(unit: model.unit).height
					model.texts[i].at = CGPoint(x: left + width / 2, y: resize.start.minY + height / 2)
					return
				}
				if moving == nil, dragStart == nil, let hit = model.hit(at: imagePoint(value.startLocation, scale)) {
					commitPendingIfNeeded(model, scale)
					model.selected = hit.id
					let origin = hit.isText
						? model.texts.filter { $0.id == hit.id }.map(\.at)
						: model.arrows.filter { $0.id == hit.id }.flatMap { [$0.from, $0.to] }
					moving = Move(id: hit.id, isText: hit.isText, origin: origin)
				}
				if var move = moving {
					let dx = value.translation.width / scale, dy = value.translation.height / scale
					guard hypot(dx, dy) > 2 || move.pushed else { return }
					if !move.pushed { model.push(); move.pushed = true; moving = move }
					if move.isText, let i = model.texts.firstIndex(where: { $0.id == move.id }), let o = move.origin.first {
						model.texts[i].at = CGPoint(x: o.x + dx, y: o.y + dy)
					} else if let i = model.arrows.firstIndex(where: { $0.id == move.id }), move.origin.count == 2 {
						model.arrows[i].from = CGPoint(x: move.origin[0].x + dx, y: move.origin[0].y + dy)
						model.arrows[i].to = CGPoint(x: move.origin[1].x + dx, y: move.origin[1].y + dy)
					}
					return
				}
				if model.tool == .text { return }
				if dragStart == nil { dragStart = value.startLocation }
				dragNow = value.location
			}
			.onEnded { value in
				defer { dragStart = nil; dragNow = nil; moving = nil; cropDrag = nil; resizing = nil }
				if model.tool == .crop {
					if let r = cropRect, r.width < 8 || r.height < 8 { cropRect = nil }
					return
				}
				if moving != nil || resizing != nil { return }
				switch model.tool {
				case .text:
					commitPendingIfNeeded(model, scale)
					createText(model, at: imagePoint(value.location, scale))
				case .arrow:
					let a = value.startLocation, b = value.location
					guard hypot(a.x - b.x, a.y - b.y) > 8 else { model.selected = nil; return }
					model.push()
					let arrow = ArrowMark(from: imagePoint(a, scale), to: imagePoint(b, scale))
					model.arrows.append(arrow)
					model.selected = arrow.id
				case .crop:
					break
				}
			}
	}

	private func imagePoint(_ p: CGPoint, _ scale: CGFloat) -> CGPoint { CGPoint(x: p.x / scale, y: p.y / scale) }

	private func commitPendingIfNeeded(_ model: ImageEditorModel, _ scale: CGFloat) {
		if editingID != nil { commitEdit(model) }
	}

	/// A click with the text tool makes an empty, already resizable text box and starts typing in it.
	private func createText(_ model: ImageEditorModel, at point: CGPoint) {
		var mark = TextMark(at: point, text: "")
		let style = model.textStyle
		mark.size = style.size; mark.color = style.color; mark.family = style.family
		mark.bold = style.bold; mark.italic = style.italic; mark.underline = style.underline; mark.align = style.align
		let width = min(240 * model.unit, model.size.width * 0.8)
		let left = max(0, min(point.x, model.size.width - width))
		mark.width = width
		mark.at = CGPoint(x: left + width / 2, y: point.y)
		model.texts.append(mark)
		model.selected = mark.id
		creatingID = mark.id
		editOriginal = ""
		draft = ""
		editingID = mark.id
		textFocused = true
	}

	/// Double-clicking a text puts its content back in a field to edit.
	private func startEditing(_ model: ImageEditorModel, at location: CGPoint, _ scale: CGFloat) {
		guard model.tool != .crop, let hit = model.hit(at: imagePoint(location, scale)), hit.isText,
			  let mark = model.texts.first(where: { $0.id == hit.id }) else { return }
		commitPendingIfNeeded(model, scale)
		model.selected = hit.id
		creatingID = nil
		editOriginal = mark.text
		draft = mark.text
		editingID = hit.id
		textFocused = true
	}

	/// Keeps the typed text, with one undo step for the whole change. An empty new text is dropped.
	private func commitEdit(_ model: ImageEditorModel) {
		defer { editingID = nil; creatingID = nil; draft = "" }
		guard let id = editingID, let i = model.texts.firstIndex(where: { $0.id == id }) else { return }
		let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		if creatingID == id {
			if text.isEmpty { model.texts.remove(at: i); model.selected = nil; return }
			var mark = model.texts.remove(at: i)
			model.push()
			mark.text = text
			model.texts.append(mark)
		} else if text.isEmpty || text == editOriginal {
			model.texts[i].text = editOriginal
		} else {
			model.texts[i].text = editOriginal
			model.push()
			model.texts[i].text = text
		}
	}

	// MARK: Side panel

	private func sidePanel(_ model: ImageEditorModel) -> some View {
		VStack(spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					if model.tool == .crop {
						cropSection(model)
					} else if model.selectedTextIndex != nil || model.tool == .text {
						textSection(model)
					} else if model.selectedArrow != nil {
						selectionHeader("Arrow", model)
					}
					if model.tool == .crop || model.tool == .text || model.selectedTextIndex != nil || model.selectedArrow != nil { Divider() }
					redactionSection(model)
				}
				.padding(16)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			VStack(spacing: 8) {
				Button(action: close) { Text("Cancel").frame(maxWidth: .infinity) }
					.buttonStyle(.pill)
					.keyboardShortcut(.cancelAction)
				Button(action: save) { Text("Done").frame(maxWidth: .infinity) }
					.buttonStyle(.pillProminent)
					.keyboardShortcut(.return, modifiers: .command)
			}
			.padding(16)
		}
		.frame(width: 280)
	}

	private func cropSection(_ model: ImageEditorModel) -> some View {
		let bounds = CGRect(origin: .zero, size: model.size)
		return VStack(alignment: .leading, spacing: 14) {
			Text("Crop").font(.system(size: 13, weight: .semibold))
			if let r = cropRect {
				LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
					cropField("X", r.minX) { setCrop(.x, $0, bounds) }
					cropField("Y", r.minY) { setCrop(.y, $0, bounds) }
					cropField("Width", r.width) { setCrop(.width, $0, bounds) }
					cropField("Height", r.height) { setCrop(.height, $0, bounds) }
				}
			}
			Text(cropRect == nil ? "Drag on the image to choose an area." : "Drag inside to move, drag a handle to resize. Hold Shift to keep the ratio.")
				.font(.system(size: 13)).foregroundStyle(.secondary)
		}
	}

	private func cropField(_ title: String, _ value: CGFloat, _ set: @escaping (Int) -> Void) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
			TextField("", value: Binding(get: { Int(value.rounded()) }, set: set), format: .number.grouping(.never))
				.textFieldStyle(.card).monospacedDigit()
		}
	}

	private enum CropField { case x, y, width, height }

	private func setCrop(_ field: CropField, _ value: Int, _ bounds: CGRect) {
		guard var r = cropRect else { return }
		let v = CGFloat(value)
		let ratio = cropFrame.ratio
		switch field {
		case .x: r.origin.x = max(0, min(v, bounds.width - r.width))
		case .y: r.origin.y = max(0, min(v, bounds.height - r.height))
		case .width:
			var w = max(8, min(v, bounds.width - r.minX))
			if let ratio { w = min(w, (bounds.height - r.minY) * ratio); r.size.height = w / ratio }
			r.size.width = w
		case .height:
			var h = max(8, min(v, bounds.height - r.minY))
			if let ratio { h = min(h, (bounds.width - r.minX) / ratio); r.size.width = h * ratio }
			r.size.height = h
		}
		cropRect = r
	}

	/// Fits the chosen frame inside the current area, or a centred one when there is none.
	private func applyFrame(_ bounds: CGRect) {
		guard let ratio = cropFrame.ratio else { return }
		let base = cropRect ?? bounds.insetBy(dx: bounds.width * 0.1, dy: bounds.height * 0.1)
		cropRect = CropMath.fit(base, ratio: ratio, bounds: bounds)
	}

	private func selectionHeader(_ title: String, _ model: ImageEditorModel) -> some View {
		HStack {
			Text(title).font(.system(size: 13, weight: .semibold))
			Spacer()
			DeleteCircleButton { model.deleteSelected() }
		}
	}

	/// Reads and writes the selected text's style, or the style new texts start with.
	private func styleBinding(_ model: ImageEditorModel) -> Binding<TextMark> {
		Binding(
			get: { model.selectedTextIndex.map { model.texts[$0] } ?? model.textStyle },
			set: { new in
				if let i = model.selectedTextIndex { model.texts[i] = new }
				model.textStyle = new
			})
	}

	private func textSection(_ model: ImageEditorModel) -> some View {
		let style = styleBinding(model)
		return VStack(alignment: .leading, spacing: 14) {
			if model.selectedTextIndex != nil { selectionHeader("Text", model) } else { Text("Text").font(.system(size: 13, weight: .semibold)) }
			HStack(spacing: 2) {
				iconButton("bold", "Bold", active: style.wrappedValue.bold, size: 28) { style.wrappedValue.bold.toggle() }
				iconButton("italic", "Italic", active: style.wrappedValue.italic, size: 28) { style.wrappedValue.italic.toggle() }
				iconButton("underline", "Underline", active: style.wrappedValue.underline, size: 28) { style.wrappedValue.underline.toggle() }
				Divider().frame(height: 18).padding(.horizontal, 3)
				SizeMenu(options: TextMark.sizes, selection: style.size)
				Divider().frame(height: 18).padding(.horizontal, 3)
				ForEach(MarkAlign.allCases) { a in
					iconButton(a.symbol, "Align \(a.rawValue)", active: style.wrappedValue.align == a, size: 28) { style.wrappedValue.align = a }
				}
			}
			VStack(alignment: .leading, spacing: 6) {
				Text("Color").font(.system(size: 13)).foregroundStyle(.secondary)
				HStack(spacing: 6) {
					ForEach(MarkColor.allCases) { c in
						Button { style.wrappedValue.color = c } label: {
							Circle().fill(c.color).frame(width: 20, height: 20)
								.overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
								.overlay(Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3).opacity(style.wrappedValue.color == c ? 1 : 0))
						}
						.buttonStyle(.plain)
					}
				}
			}
			FieldPicker(title: "Font", options: TextMark.families, selection: style.family) { $0 }
		}
	}

	private func redactionSection(_ model: ImageEditorModel) -> some View {
		@Bindable var model = model
		return VStack(alignment: .leading, spacing: 12) {
			HStack {
				Text("Hide sensitive data").font(.system(size: 13))
				Spacer()
				Toggle("", isOn: $model.redact)
					.labelsHidden().toggleStyle(.switch).controlSize(.mini)
					.onChange(of: model.redact) { _, on in if on { model.detect() } }
			}
			if model.redact {
				FieldPicker(title: "Style", options: RedactionStyle.allCases, selection: $model.style) { $0.rawValue }
				Text("Found in the image").font(.system(size: 13)).foregroundStyle(.secondary)
				VStack(alignment: .leading, spacing: 8) {
					ForEach(SensitiveKind.allCases) { kind in
						let on = Binding(
							get: { model.kinds.contains(kind) },
							set: { if $0 { model.kinds.insert(kind) } else { model.kinds.remove(kind) } })
						HStack(spacing: 12) {
							Toggle("", isOn: on).labelsHidden().toggleStyle(.checkbox)
							Text(kind.title).font(.system(size: 13))
							Spacer()
							Text("\(model.count(kind))").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.contentShape(Rectangle())
						.onTapGesture { on.wrappedValue.toggle() }
						.pointerCursor()
					}
				}
				if model.detecting { ProgressView().controlSize(.small) }
				Text("Detection reads the text in the picture and can miss some. Check the result before sending.")
					.font(.system(size: 13)).foregroundStyle(.tertiary)
			} else {
				Text("Turn on to blur or cover emails, names, addresses and more.").font(.system(size: 13)).foregroundStyle(.secondary)
			}
		}
	}

	// MARK: Save

	private func save() {
		guard let model else { return }
		commitPendingIfNeeded(model, 1)
		guard let data = model.render() else { close(); return }
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mailflare-edits/\(UUID().uuidString)", isDirectory: true)
		let base = (session.name as NSString).deletingPathExtension
		let url = dir.appendingPathComponent(base + ".png")
		do {
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
			try data.write(to: url)
			session.onSave(url)
		} catch {}
		close()
	}
}


/// A dropdown drawn like an input: its label on one row, the field on the next.
private struct FieldPicker<T: Hashable>: View {
	let title: String
	let options: [T]
	@Binding var selection: T
	let label: (T) -> String

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
			Menu {
				ForEach(options, id: \.self) { option in
					Button { selection = option } label: {
						if option == selection { Label(label(option), systemImage: "checkmark") } else { Text(label(option)) }
					}
				}
			} label: {
				HStack {
					Text(label(selection)).font(.system(size: 13)).lineLimit(1)
					Spacer(minLength: 4)
					Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
				}
				.padding(.horizontal, 12).padding(.vertical, 8)
				.frame(maxWidth: .infinity)
				.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
				.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.composerStroke, lineWidth: 1))
				.contentShape(Rectangle())
			}
			.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
		}
	}
}


// MARK: Crop geometry

enum CropFrame: String, CaseIterable, Identifiable {
	case free, square, portrait, landscape
	var id: String { rawValue }
	var title: String {
		switch self { case .free: "Free"; case .square: "Square (1:1)"; case .portrait: "Portrait (3:4)"; case .landscape: "Landscape (4:3)" }
	}
	/// Width over height; nil leaves the area free.
	var ratio: CGFloat? {
		switch self { case .free: nil; case .square: 1; case .portrait: 3.0 / 4.0; case .landscape: 4.0 / 3.0 }
	}
}

enum CropHandle: Equatable {
	case move, create
	/// -1 / 0 / 1 on each axis: which edges or corner is being dragged.
	case edge(h: Int, v: Int)
}

struct CropDrag { var handle: CropHandle; var start: CGRect; var origin: CGPoint }

enum CropMath {
	static let minimum: CGFloat = 8

	static func handle(at p: CGPoint, in r: CGRect, tolerance t: CGFloat) -> CropHandle {
		let withinX = p.x >= r.minX - t && p.x <= r.maxX + t
		let withinY = p.y >= r.minY - t && p.y <= r.maxY + t
		let h = withinY ? (abs(p.x - r.minX) <= t ? -1 : abs(p.x - r.maxX) <= t ? 1 : 0) : 0
		let v = withinX ? (abs(p.y - r.minY) <= t ? -1 : abs(p.y - r.maxY) <= t ? 1 : 0) : 0
		if h != 0 || v != 0 { return .edge(h: h, v: v) }
		return r.contains(p) ? .move : .create
	}

	/// A rectangle with one corner fixed at `anchor` and the opposite one following `point`, kept inside `bounds`.
	static func anchored(anchor: CGPoint, to point: CGPoint, ratio: CGFloat?, bounds: CGRect) -> CGRect {
		let sx: CGFloat = point.x >= anchor.x ? 1 : -1, sy: CGFloat = point.y >= anchor.y ? 1 : -1
		let maxW = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
		let maxH = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
		var w = min(abs(point.x - anchor.x), maxW), h = min(abs(point.y - anchor.y), maxH)
		if let ratio {
			if w / max(h, 0.001) > ratio { w = h * ratio } else { h = w / ratio }
		}
		return CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
	}

	/// Drags one edge of `start`. With a ratio the other axis follows, around the rectangle's centre.
	static func edge(start: CGRect, h: Int, v: Int, to p: CGPoint, ratio: CGFloat?, bounds: CGRect) -> CGRect {
		var r = start
		if let ratio {
			if h != 0 {
				var w = h < 0 ? start.maxX - p.x : p.x - start.minX
				let capHeight = 2 * min(start.midY - bounds.minY, bounds.maxY - start.midY)
				w = max(minimum, min(w, h < 0 ? start.maxX - bounds.minX : bounds.maxX - start.minX, capHeight * ratio))
				let height = w / ratio
				return CGRect(x: h < 0 ? start.maxX - w : start.minX, y: start.midY - height / 2, width: w, height: height)
			}
			var height = v < 0 ? start.maxY - p.y : p.y - start.minY
			let capWidth = 2 * min(start.midX - bounds.minX, bounds.maxX - start.midX)
			height = max(minimum, min(height, v < 0 ? start.maxY - bounds.minY : bounds.maxY - start.minY, capWidth / ratio))
			let w = height * ratio
			return CGRect(x: start.midX - w / 2, y: v < 0 ? start.maxY - height : start.minY, width: w, height: height)
		}
		if h < 0 { let x = max(bounds.minX, min(p.x, start.maxX - minimum)); r = CGRect(x: x, y: r.minY, width: start.maxX - x, height: r.height) }
		if h > 0 { r.size.width = max(minimum, min(p.x, bounds.maxX) - start.minX) }
		if v < 0 { let y = max(bounds.minY, min(p.y, start.maxY - minimum)); r = CGRect(x: r.minX, y: y, width: r.width, height: start.maxY - y) }
		if v > 0 { r.size.height = max(minimum, min(p.y, bounds.maxY) - start.minY) }
		return r
	}

	/// The largest rectangle with `ratio` that fits inside `rect`, centred in it.
	static func fit(_ rect: CGRect, ratio: CGFloat, bounds: CGRect) -> CGRect {
		let r = rect.intersection(bounds)
		var w = r.width, h = r.height
		if w / max(h, 0.001) > ratio { w = h * ratio } else { h = w / ratio }
		return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
	}
}

private extension CGPoint {
	func clamped(to r: CGRect) -> CGPoint { CGPoint(x: max(r.minX, min(x, r.maxX)), y: max(r.minY, min(y, r.maxY))) }
}

private struct PointerCursor: ViewModifier {
	@State private var inside = false
	func body(content: Content) -> some View {
		content
			.onHover { hovering in
				if hovering, !inside { NSCursor.pointingHand.push(); inside = true }
				else if !hovering, inside { NSCursor.pop(); inside = false }
			}
			.onDisappear { if inside { NSCursor.pop(); inside = false } }
	}
}

private extension View {
	func pointerCursor() -> some View { modifier(PointerCursor()) }
}


/// A flat icon button with the app's own tooltip (the system's `.help` is not reliable in this window).
private struct EditorIconButton: View {
	let symbol: String
	let help: String
	let active: Bool
	let size: CGFloat
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Image(systemName: symbol).font(.system(size: size * 0.45))
				.frame(width: size, height: size - 4)
				.background(
					active ? Color.accentColor.opacity(0.25) : hovering ? AppTheme.railSelection.opacity(0.6) : .clear,
					in: RoundedRectangle(cornerRadius: 8, style: .continuous))
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.titlebarTooltip(help, isHovering: hovering)
		.accessibilityLabel(help)
	}
}


/// The font size as a number with a dropdown of sizes, small enough to share a row with the format buttons.
private struct SizeMenu: View {
	let options: [CGFloat]
	@Binding var selection: CGFloat

	var body: some View {
		Menu {
			ForEach(options, id: \.self) { size in
				Button { selection = size } label: {
					if size == selection { Label("\(Int(size))", systemImage: "checkmark") } else { Text("\(Int(size))") }
				}
			}
		} label: {
			HStack(spacing: 3) {
				Text("\(Int(selection))").font(.system(size: 13)).monospacedDigit()
				Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
			}
			.padding(.horizontal, 6).frame(width: 50, height: 24)
			.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.composerStroke, lineWidth: 1))
			.contentShape(Rectangle())
		}
		.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
	}
}


/// The trash button: a small icon that gets a light circle behind it on hover.
private struct DeleteCircleButton: View {
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Image(systemName: "trash").font(.system(size: 11))
				.frame(width: 24, height: 24)
				.background(Circle().fill(hovering ? AppTheme.railSelection.opacity(0.7) : .clear))
				.contentShape(Circle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.titlebarTooltip("Delete", isHovering: hovering, trailing: true)
		.accessibilityLabel("Delete")
	}
}
