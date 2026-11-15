import SwiftUI

// MARK: Window metrics

/// The height of a pane's top row. The message list's header and the reader's top row share it, so
/// their hairlines line up across the card.
enum PaneHeader {
	static let height: CGFloat = 52
}

enum WindowChromeMetrics {
	/// The titlebar band: the traffic lights are centred in it and the content card starts under it.
	static let titlebarHeight: CGFloat = 40
	static let titlebarRowCenter: CGFloat = 19
	static let cardInset: CGFloat = 6
	static let cardCornerRadius: CGFloat = 12
	/// Where the sidebar toggle starts: just past the traffic lights.
	static let sidebarToggleLeading: CGFloat = 84
}

enum RailMetrics {
	/// The glyph size shared by the titlebar's buttons.
	static let iconSize: CGFloat = 17
}

// MARK: Buttons

/// The soft grey pill used for actions ("Discard", "Summarize"); `prominent` is the filled one.
struct PillButtonStyle: ButtonStyle {
	var prominent = false
	@Environment(\.isEnabled) private var isEnabled

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.system(size: 13, weight: .medium))
			.foregroundStyle(prominent ? AppTheme.prominentPillText : Color.primary)
			.padding(.horizontal, 14)
			.padding(.vertical, 7)
			.background(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.fill(prominent ? AppTheme.prominentPillFill : AppTheme.railSelection.opacity(0.7))
			)
			.opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
	}
}

extension ButtonStyle where Self == PillButtonStyle {
	static var pill: PillButtonStyle { PillButtonStyle() }
	static var pillProminent: PillButtonStyle { PillButtonStyle(prominent: true) }
}

/// A button drawn entirely by SwiftUI, dimmed while pressed. Used for rows and links.
struct LightButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label.opacity(configuration.isPressed ? 0.5 : 1).contentShape(Rectangle())
	}
}

extension ButtonStyle where Self == LightButtonStyle {
	static var light: LightButtonStyle { LightButtonStyle() }
}

// MARK: Surfaces and fields

/// The surface for everything beside the message itself: summaries, chips, notices.
struct NoticeSurface: ViewModifier {
	var radius: CGFloat = 16
	func body(content: Content) -> some View {
		content
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
			.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
	}
}

extension View {
	func noticeSurface(radius: CGFloat = 16) -> some View { modifier(NoticeSurface(radius: radius)) }
}

/// An input drawn as a soft rounded field.
struct CardFieldStyle: TextFieldStyle {
	func _body(configuration: TextField<Self._Label>) -> some View {
		configuration
			.textFieldStyle(.plain)
			.font(Typography.body)
			.padding(.horizontal, 12)
			.padding(.vertical, 10)
			.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.composerStroke, lineWidth: 1))
	}
}

extension TextFieldStyle where Self == CardFieldStyle {
	static var card: CardFieldStyle { CardFieldStyle() }
}

/// A secure field in the same soft box.
struct CardSecureField: View {
	var title: String
	@Binding var text: String

	var body: some View {
		SecureField(title, text: $text)
			.textFieldStyle(.plain)
			.font(Typography.body)
			.padding(.horizontal, 12)
			.padding(.vertical, 10)
			.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.composerStroke, lineWidth: 1))
	}
}

// MARK: Banner and empty state

struct BannerView: View {
	var title: String
	var onDismiss: () -> Void

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			HIcon(.junk, size: 15).foregroundStyle(.red).padding(.top, 1)
			Text(title)
				.font(Typography.notice)
				.fixedSize(horizontal: false, vertical: true)
				.textSelection(.enabled)
			Spacer(minLength: 8)
			Button(action: onDismiss) { HIcon(.close, size: 13) }
				.buttonStyle(.light).foregroundStyle(.secondary).help("Dismiss")
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
		.shadow(color: AppTheme.composerShadow, radius: 10, y: 4)
		.frame(maxWidth: 520)
	}
}

/// A short confirmation card: an icon (or spinner), a title and the message it is about.
struct ToastView: View {
	var toast: Toast

	var body: some View {
		HStack(spacing: 10) {
			if toast.isProgress {
				ProgressView().controlSize(.small)
			} else {
				HIcon(toast.icon, size: 15).foregroundStyle(.green)
			}
			VStack(alignment: .leading, spacing: 1) {
				Text(toast.title).font(Typography.bodySemibold)
				if !toast.detail.isEmpty {
					Text(toast.detail).font(Typography.meta).foregroundStyle(.secondary).lineLimit(1)
				}
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.frame(maxWidth: 320, alignment: .leading)
		.fixedSize(horizontal: true, vertical: false)
		.background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
		.shadow(color: AppTheme.composerShadow, radius: 12, y: 4)
	}
}

struct EmptyStateView: View {
	var icon: AppIcon
	var title: String
	var message: String?

	var body: some View {
		VStack(spacing: 10) {
			HIcon(icon, size: 34).foregroundStyle(.tertiary)
			Text(title).font(.system(size: 16, weight: .regular)).multilineTextAlignment(.center)
			if let message {
				Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
			}
		}
		.padding(28)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}


// MARK: Window visibility

/// Shows or hides the window this view sits in, without closing its scene. SwiftUI opens every
/// scene at launch, so the app decides what is on screen from the sign-in state instead.
struct WindowVisibility: NSViewRepresentable {
	var isVisible: Bool

	final class Host: NSView {
		var isVisible = false { didSet { apply() } }
		override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }

		/// SwiftUI may order a scene's window front a moment after its view is attached, so the check
		/// repeats briefly instead of running once.
		func apply() {
			for delay in [0.0, 0.2, 0.6] {
				DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
					guard let self, let window else { return }
					if isVisible {
						if !window.isVisible {
							window.makeKeyAndOrderFront(nil)
							NSApp.activate(ignoringOtherApps: true)
						}
					} else if window.isVisible {
						window.orderOut(nil)
					}
				}
			}
		}
	}

	func makeNSView(context: Context) -> Host { Host() }
	func updateNSView(_ view: Host, context: Context) { view.isVisible = isVisible }
}


// MARK: Loader bar

/// A thin indeterminate bar for loading states: a short accent segment sweeping left to right
/// along a hairline. It always occupies its 2pt of height, so showing it never shifts the layout.
struct LoaderBar: View {
	var isActive: Bool
	/// Waits a moment before showing, so a load that finishes at once never flashes the bar (and
	/// never starts the animation, which redraws at the display's rate).
	@State private var isShown = false

	var body: some View {
		ZStack {
			if isActive && isShown {
				TimelineView(.animation) { timeline in
					GeometryReader { geo in
						let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
						let segment = geo.size.width * 0.35
						Capsule()
							.fill(Color.accentColor)
							.frame(width: segment)
							.offset(x: -segment + (geo.size.width + segment) * t)
					}
				}
			}
		}
		.frame(height: 2)
		.frame(maxWidth: .infinity)
		.task(id: isActive) {
			guard isActive else { isShown = false; return }
			try? await Task.sleep(for: .milliseconds(250))
			if !Task.isCancelled { isShown = true }
		}
		.background(isActive ? AppTheme.cardStroke : Color.clear)
		.clipped()
		.animation(.easeInOut(duration: 0.15), value: isActive)
		.accessibilityHidden(true)
	}
}


// MARK: Titlebar controls

/// A titlebar glyph button: the rail's glyph size in a 26pt square that lifts on hover.
struct TitlebarIconButton: View {
	static let size: CGFloat = 26

	var icon: AppIcon
	var help: String
	var tint: Color?
	var isActive = false
	var isEnabled = true
	/// Looks disabled but keeps its tooltip, to say why the button does nothing.
	var isDimmed = false
	/// For buttons at the window's right edge: the tooltip ends at the button instead of centring on it.
	var tooltipTrailing = false
	var tooltipAbove = false
	var iconSize: CGFloat = RailMetrics.iconSize
	/// Shows a spinner in place of the icon while work is under way.
	var isLoading = false
	var action: () -> Void

	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			Group {
				if isLoading { ProgressView().controlSize(.small).scaleEffect(0.7) } else { HIcon(icon, size: iconSize) }
			}
				.frame(width: Self.size, height: Self.size)
				.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isHovering ? AppTheme.railSelection.opacity(0.6) : .clear))
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!isEnabled)
		.opacity(isEnabled && !isDimmed ? 1 : 0.35)
		.foregroundStyle(tint ?? ((isActive || isHovering) && !isDimmed ? Color.primary : Color.secondary))
		.onHover { isHovering = $0 && isEnabled }
		.titlebarTooltip(help, isHovering: isHovering, trailing: tooltipTrailing, above: tooltipAbove)
		.accessibilityLabel(help)
	}
}

/// A titlebar menu drawn like `TitlebarIconButton`; with `primaryAction` it is a split button.
struct TitlebarMenu<Content: View>: View {
	var icon: AppIcon
	var help: String
	var tint: Color?
	var isEnabled = true
	var primaryAction: (() -> Void)?
	@ViewBuilder var content: Content

	@State private var isHovering = false

	var body: some View {
		let label = HIcon(icon, size: RailMetrics.iconSize)
			.frame(width: TitlebarIconButton.size, height: TitlebarIconButton.size)
			.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isHovering ? AppTheme.railSelection.opacity(0.6) : .clear))
			.contentShape(Rectangle())
		Group {
			if let primaryAction {
				Menu { content } label: { label } primaryAction: { primaryAction() }
			} else {
				Menu { content } label: { label }
			}
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()
		.disabled(!isEnabled)
		.opacity(isEnabled ? 1 : 0.35)
		.foregroundStyle(tint ?? (isHovering ? Color.primary : Color.secondary))
		.onHover { isHovering = $0 && isEnabled }
		.titlebarTooltip(help, isHovering: isHovering)
		.accessibilityLabel(help)
	}
}

/// The help text under a titlebar control, shown after a short hover. The system's `.help`
/// tooltips never appear over the hidden titlebar, so this one is drawn by SwiftUI.
struct TitlebarTooltip: ViewModifier {
	var text: String
	var isHovering: Bool
	var trailing = false
	/// Opens above the control and starts at its leading edge, to stay inside a panel's bottom-left corner.
	var above = false
	@State private var isShown = false

	func body(content: Content) -> some View {
		content
			.overlay(alignment: above ? .topLeading : trailing ? .topTrailing : .top) {
				if isShown {
					Text(text)
						.font(.system(size: 11))
						.foregroundStyle(.primary)
						.fixedSize()
						.padding(.horizontal, 7)
						.padding(.vertical, 3)
						.background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
						.overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
						.shadow(color: AppTheme.composerShadow, radius: 4, y: 2)
						.offset(y: above ? -(TitlebarIconButton.size + 2) : TitlebarIconButton.size + 6)
						.allowsHitTesting(false)
						.transition(.opacity)
				}
			}
			.zIndex(isShown ? 1000 : 0)
			.task(id: isHovering) {
				guard isHovering else { isShown = false; return }
				try? await Task.sleep(for: .milliseconds(500))
				if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { isShown = true } }
			}
	}
}

extension View {
	func titlebarTooltip(_ text: String, isHovering: Bool, trailing: Bool = false, above: Bool = false) -> some View {
		modifier(TitlebarTooltip(text: text, isHovering: isHovering, trailing: trailing, above: above))
	}
}

/// A one-point rule between panes that can be dragged to resize them.
struct PaneDivider: View {
	var onChanged: (CGFloat) -> Void
	var onEnded: () -> Void

	var body: some View {
		Rectangle()
			.fill(AppTheme.cardStroke)
			.frame(width: 1)
			.contentShape(Rectangle().inset(by: -3))
			.onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
			.gesture(DragGesture().onChanged { onChanged($0.translation.width) }.onEnded { _ in onEnded() })
	}
}


/// An invisible strip that resizes the pane beside it when dragged; the cursor shows the way.
struct ResizeHandle: View {
	var onChanged: (CGFloat) -> Void
	var onEnded: () -> Void

	var body: some View {
		Color.clear
			.frame(width: 8)
			.contentShape(Rectangle())
			.onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
			.gesture(DragGesture(minimumDistance: 1).onChanged { onChanged($0.translation.width) }.onEnded { _ in onEnded() })
	}
}


/// Reports the enclosing scroll view's offset (points scrolled from the top) and visible height
/// every time it scrolls or resizes. It watches the scroll view's own clip view, which updates
/// during scrolling, unlike a layout preference.
struct ScrollObserver: NSViewRepresentable {
	var onChange: (_ offset: CGFloat, _ viewport: CGFloat) -> Void

	func makeNSView(context: Context) -> Host { Host(onChange: onChange) }
	func updateNSView(_ view: Host, context: Context) { view.onChange = onChange }

	final class Host: NSView {
		var onChange: (CGFloat, CGFloat) -> Void
		private var observer: NSObjectProtocol?

		init(onChange: @escaping (CGFloat, CGFloat) -> Void) {
			self.onChange = onChange
			super.init(frame: .zero)
		}

		required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			// The scroll view above is attached once SwiftUI has finished laying out.
			DispatchQueue.main.async { [weak self] in self?.attach() }
		}

		private func attach() {
			guard observer == nil, let scrollView = enclosingScrollView else { return }
			let clip = scrollView.contentView
			clip.postsBoundsChangedNotifications = true
			clip.postsFrameChangedNotifications = true
			let report: (Notification) -> Void = { [weak self] _ in self?.report() }
			observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: report)
			NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main, using: report)
			report(Notification(name: NSView.boundsDidChangeNotification))
		}

		private func report() {
			guard let scrollView = enclosingScrollView, let document = scrollView.documentView else { return }
			let clip = scrollView.contentView
			let offset = document.isFlipped ? clip.bounds.minY : document.frame.height - clip.bounds.maxY
			onChange(max(0, offset), clip.bounds.height)
		}

		deinit { NotificationCenter.default.removeObserver(self) }
	}
}


// MARK: Dropdowns

/// The card every dropdown opens as: the account dropdown's surface, border and shadow.
struct DropdownCard<Content: View>: View {
	/// A fixed width, or nil to take the width of the view it opens from.
	var width: CGFloat? = 200
	var anchor: UnitPoint = .topTrailing
	var spacing: CGFloat = 2
	@ViewBuilder var content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: spacing) { content }
			.padding(4)
			.frame(minWidth: width, maxWidth: width ?? .infinity)
			.background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
			.shadow(color: AppTheme.composerShadow, radius: 14, y: 6)
			.transition(.opacity.combined(with: .scale(scale: 0.98, anchor: anchor)))
	}
}

/// One line of a dropdown: a label, with a check when chosen, a chevron when it opens more, or a
/// delete button on hover.
struct DropdownRow: View {
	var label: String
	var detail: String?
	var icon: AppIcon?
	var iconRotation = 0.0
	var isSelected = false
	var trailing: AppIcon?
	var isEnabled = true
	var onDelete: (() -> Void)?
	/// With `onDelete`, a pencil beside the trash on hover.
	var onEdit: (() -> Void)?
	/// Replaces the label's font where a menu wants it smaller.
	var labelFont: Font?
	var verticalPadding: CGFloat = 7
	var action: () -> Void

	@State private var isHovering = false

	var body: some View {
		ZStack(alignment: .trailing) {
			Button(action: action) {
				HStack(spacing: 8) {
					if let icon { HIcon(icon, size: 14).foregroundStyle(.secondary).rotationEffect(.degrees(iconRotation)) }
					Text(label).font(labelFont ?? Typography.body).lineLimit(1)
					Spacer(minLength: 8)
					if let detail { Text(detail).font(Typography.meta).foregroundStyle(.secondary).lineLimit(1) }
					if isSelected { HIcon(.check, size: 14) }
					if let trailing { HIcon(trailing, size: 12).foregroundStyle(.secondary) }
				}
				.padding(.horizontal, 10).padding(.vertical, verticalPadding)
				.background(RoundedRectangle(cornerRadius: 9, style: .continuous)
					.fill(isSelected ? AppTheme.railSelection : (isHovering && isEnabled ? AppTheme.rowHighlight : .clear)))
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.disabled(!isEnabled)
			.opacity(isEnabled ? 1 : 0.4)
			if (onDelete != nil || onEdit != nil), isHovering {
				HStack(spacing: 0) {
					if let onEdit {
						Button(action: onEdit) { HIcon(.edit, size: 13).foregroundStyle(.secondary).padding(6).contentShape(Rectangle()) }
							.buttonStyle(.plain).help("Edit")
					}
					if let onDelete {
						Button(action: onDelete) { HIcon(.trash, size: 13).foregroundStyle(.secondary).padding(6).contentShape(Rectangle()) }
							.buttonStyle(.plain).help("Delete")
					}
				}
				.padding(.trailing, 6)
			}
		}
		.onHover { isHovering = $0 }
	}
}

/// A small heading inside a dropdown.
struct DropdownLabel: View {
	var title: String
	var body: some View {
		Text(title).font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
			.padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
	}
}

/// A search field at the top of a long dropdown, focused when it opens. Typing finds the first
/// matching row (the caller scrolls to it); Return chooses it.
struct DropdownSearchField: View {
	@Binding var text: String
	var onSubmit: () -> Void
	@FocusState private var focused: Bool

	var body: some View {
		HStack(spacing: 6) {
			HIcon(.search, size: 13).foregroundStyle(.secondary)
			TextField("Type to search", text: $text)
				.textFieldStyle(.plain).font(Typography.body)
				.focused($focused)
				.onSubmit(onSubmit)
		}
		.padding(.horizontal, 8).padding(.vertical, 6)
		.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
		.padding(.horizontal, 2).padding(.bottom, 2)
		.onAppear { focused = true }
	}
}

/// A dropdown's scrolling list. It is as tall as its rows, up to `maxHeight` (measured, so a list
/// that fills in later still gets the right height), and scrolls to `target` when that changes.
struct DropdownScroll<Content: View>: View {
	var maxHeight: CGFloat = 280
	var target: String?
	@ViewBuilder var content: Content
	@State private var contentHeight: CGFloat = 0

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				// Lazy: only the rows near the viewport exist, so a catalogue of hundreds opens at once.
				LazyVStack(alignment: .leading, spacing: 2) { content }
					.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
			}
			.frame(height: min(max(contentHeight, 1), maxHeight))
			.onAppear { if let target { proxy.scrollTo(target, anchor: .center) } }
			.onChange(of: target) { _, new in if let new { proxy.scrollTo(new, anchor: .top) } }
		}
	}
}

extension View {
	/// The row a search matched, tinted so it stands out in the list.
	func searchMatch(_ isMatch: Bool) -> some View {
		background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isMatch ? AppTheme.rowHighlight : .clear).padding(.horizontal, 4))
	}
}

/// What a searched dropdown shows when nothing matches.
struct DropdownNoResults: View {
	var body: some View {
		Text("No item found").font(Typography.body).italic().foregroundStyle(.tertiary)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 10).padding(.vertical, 8)
	}
}

struct DropdownDivider: View {
	var body: some View { Rectangle().fill(AppTheme.cardStroke).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 3) }
}

extension View {
	/// While `isActive`, a click anywhere else calls `dismiss`. Put it on the view that owns the dropdown.
	func clickAway(isActive: Bool, dismiss: @escaping () -> Void) -> some View {
		background {
			if isActive {
				Color.clear.frame(width: 3000, height: 3000).contentShape(Rectangle()).onTapGesture(perform: dismiss)
			}
		}
	}
}

/// Set by an open dropdown, so what holds it can be drawn above the views after it.
struct DropdownOpenKey: PreferenceKey {
	static let defaultValue = false
	static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct RaisedWhileDropdownOpen: ViewModifier {
	@State private var isOpen = false

	func body(content: Content) -> some View {
		content
			.onPreferenceChange(DropdownOpenKey.self) { isOpen = $0 }
			.zIndex(isOpen ? 10 : 0)
	}
}

extension View {
	/// Draws this view above its siblings while a dropdown inside it is open, so the card is not
	/// covered by what follows. Put it on each row or block that holds a dropdown.
	func raisedWhileDropdownOpen() -> some View { modifier(RaisedWhileDropdownOpen()) }
}

/// A button that opens a `DropdownCard` of `items` just below it, or above it when there is no room
/// below in the window. A click anywhere else closes it. `reservedBelow` is room to leave at the
/// window's bottom, for a footer the card must not slide under.
struct DropdownAnchor<Label: View, Items: View>: View {
	var width: CGFloat = 190
	var itemCount: Int
	var reservedBelow: CGFloat = 0
	@Binding var isOpen: Bool
	@ViewBuilder var label: Label
	@ViewBuilder var items: Items

	@State private var frame = CGRect.zero

	private var opensUp: Bool {
		guard let window = NSApp.keyWindow?.contentView?.bounds.height else { return false }
		let below = window - reservedBelow - frame.maxY
		return below < CGFloat(itemCount) * 33 + 12 && frame.minY > below
	}

	var body: some View {
		let up = opensUp
		Button { withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() } } label: { label }
			.buttonStyle(.plain)
			.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
			.overlay(alignment: up ? .bottomLeading : .topLeading) {
				if isOpen {
					DropdownCard(width: width, anchor: up ? .bottomLeading : .topLeading) { items }
						.offset(y: up ? -(frame.height + 4) : frame.height + 4)
				}
			}
			.clickAway(isActive: isOpen) { withAnimation(.snappy(duration: 0.2)) { isOpen = false } }
			.preference(key: DropdownOpenKey.self, value: isOpen)
	}
}

/// A choice drawn with a chevron; opening it drops the same card as Settings' pickers, with a check on
/// the chosen row. It is the sibling of Settings' row picker for forms.
struct DropdownPicker<Value: Hashable>: View {
	enum Style {
		/// A soft bordered field, as wide as it is given.
		case field
		/// A shorter field, as wide as its value, to sit in a line of text.
		case compact
		/// No box of its own, for a segment of a field that draws one around several controls.
		case bare
	}

	var options: [(label: String, value: Value)]
	@Binding var selection: Value
	var width: CGFloat = 190
	var style = Style.field
	var reservedBelow: CGFloat = 0
	@State private var isOpen = false

	private var currentLabel: String { options.first { $0.value == selection }?.label ?? "" }

	var body: some View {
		DropdownAnchor(width: width, itemCount: options.count, reservedBelow: reservedBelow, isOpen: $isOpen) {
			HStack(spacing: 6) {
				Text(currentLabel).font(Typography.body).lineLimit(1)
				if style != .compact { Spacer(minLength: 4) }
				HIcon(.chevronDown, size: 12).foregroundStyle(.secondary)
					.rotationEffect(.degrees(isOpen ? 180 : 0))
			}
			.padding(.horizontal, style == .compact ? 10 : 12).padding(.vertical, style == .compact ? 5 : 10)
			.modifier(PickerBox(style: style))
			.contentShape(Rectangle())
		} items: {
			ForEach(options.indices, id: \.self) { index in
				DropdownRow(label: options[index].label, isSelected: options[index].value == selection) {
					selection = options[index].value
					withAnimation(.snappy(duration: 0.2)) { isOpen = false }
				}
			}
		}
		.fixedSize(horizontal: style == .compact, vertical: false)
	}

	private struct PickerBox: ViewModifier {
		var style: Style

		func body(content: Content) -> some View {
			let radius: CGFloat = style == .compact ? 9 : 12
			switch style {
			case .bare: content
			default:
				content
					.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
					.overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(AppTheme.composerStroke, lineWidth: 1))
			}
		}
	}
}

// MARK: Skeleton

/// A grey placeholder bar that breathes while content loads.
struct SkeletonBar: View {
	var width: CGFloat?
	var height: CGFloat = 12
	@State private var isDim = false

	var body: some View {
		RoundedRectangle(cornerRadius: height / 2, style: .continuous)
			.fill(AppTheme.railSelection)
			.frame(width: width, height: height)
			.frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
			.opacity(isDim ? 0.35 : 0.8)
			.onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isDim = true } }
	}
}
