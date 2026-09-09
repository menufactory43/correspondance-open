import AppKit
import SwiftUI

/// Un champ qui grandit avec ce qu'on y écrit, et qui suit la largeur qu'on
/// lui donne.
///
/// `TextField(axis: .vertical)` ne déclare que la largeur de sa plus longue
/// ligne, composée sur sa largeur PRÉCÉDENTE : une fenêtre détachée qu'on
/// élargit garde la césure de l'ancienne, rétrécie elle déborde, et sa hauteur
/// oublie l'interligne — à trois lignes, la dernière passe sous le bord. Ici le
/// conteneur de texte suit la vue, et la hauteur est celle que le moteur de
/// mise en page a réellement employée.
struct GrowingTextEditor: NSViewRepresentable {
  /// Les touches que la page veut arbitrer avant le champ.
  enum Command {
    case send, escape, moveUp, moveDown, tab
  }

  @Binding var text: String
  @Binding var isFocused: Bool
  var placeholder: String
  var font: NSFont
  var textColor: NSColor
  var placeholderColor: NSColor
  var caretColor: NSColor
  var lineSpacing: CGFloat
  /// Au-delà, le champ cesse de grandir et défile.
  var maxLines: Int = 20
  /// Un plafond en points, en plus des lignes : la fenêtre détachée le pose
  /// à la moitié de sa hauteur pour que le fil garde la sienne.
  var maxHeight: CGFloat?
  /// `true` = la commande est prise ; sinon le champ fait comme d'habitude
  /// (Entrée insère une ligne, ↑ ↓ déplacent le curseur…).
  var onCommand: (Command) -> Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = EditorTextView()
    textView.delegate = context.coordinator
    textView.commandHandler = { [coordinator = context.coordinator] in
      coordinator.parent.onCommand($0)
    }
    textView.focusHandler = { [coordinator = context.coordinator] focused in
      coordinator.noteFocus(focused)
    }
    textView.drawsBackground = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isContinuousSpellCheckingEnabled = true
    // Comme le champ d'avant : ce qu'on tape reste ce qu'on a tapé.
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0, height: CGFloat.greatestFiniteMagnitude
    )
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
    )

    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.verticalScrollElasticity = .none

    context.coordinator.textView = textView
    apply(to: textView, coordinator: context.coordinator)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    guard let textView = coordinator.textView else { return }
    apply(to: textView, coordinator: coordinator)

    // Le focus demandé par la page : on ne touche au premier répondant que
    // s'il diffère, et jamais pendant qu'on rend compte d'un changement.
    guard !coordinator.isReportingFocus, let window = textView.window else { return }
    let isFirst = window.firstResponder === textView
    if isFocused, !isFirst {
      window.makeFirstResponder(textView)
    } else if !isFocused, isFirst {
      window.makeFirstResponder(nil)
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
    guard let textView = context.coordinator.textView else { return nil }
    let width = proposal.width.map { max($0, 1) } ?? max(textView.bounds.width, 1)
    let lineHeight = textView.lineHeight
    let contentHeight = textView.usedHeight(forWidth: width)
    var height = min(
      max(contentHeight, lineHeight),
      lineHeight * CGFloat(maxLines) + lineSpacing * CGFloat(maxLines - 1)
    )
    if let maxHeight { height = min(height, max(maxHeight, lineHeight)) }
    return CGSize(width: width, height: ceil(height))
  }

  /// Pose police, encres, interligne et texte — sans réécrire ce que l'on est
  /// en train de taper.
  private func apply(to textView: EditorTextView, coordinator: Coordinator) {
    let attributes = typingAttributes
    textView.font = font
    textView.textColor = textColor
    textView.insertionPointColor = caretColor
    textView.typingAttributes = attributes
    textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
    textView.placeholder = placeholder
    textView.placeholderAttributes = [
      .font: font,
      .foregroundColor: placeholderColor,
      .paragraphStyle: attributes[.paragraphStyle] ?? NSParagraphStyle.default,
    ]

    if textView.string != text {
      coordinator.isSettingText = true
      textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
      textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
      coordinator.isSettingText = false
    } else if let storage = textView.textStorage, storage.length > 0 {
      // Un thème ou un corps qui change : le texte déjà écrit suit.
      let current = storage.attributes(at: 0, effectiveRange: nil)
      if (current[.font] as? NSFont) != font
        || (current[.foregroundColor] as? NSColor) != textColor
        || (current[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing != lineSpacing
      {
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
      }
    }
    textView.needsDisplay = true
  }

  private var typingAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    paragraph.lineBreakMode = .byWordWrapping
    return [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph]
  }

  // MARK: - Coordinateur

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: GrowingTextEditor
    weak var textView: EditorTextView?
    var isSettingText = false
    var isReportingFocus = false

    init(_ parent: GrowingTextEditor) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard !isSettingText, let textView else { return }
      parent.text = textView.string
    }

    func noteFocus(_ focused: Bool) {
      guard parent.isFocused != focused else { return }
      isReportingFocus = true
      parent.isFocused = focused
      isReportingFocus = false
    }
  }
}

/// Le `NSTextView` derrière : mesure, texte d'invite, et les touches que la
/// page arbitre avant lui.
final class EditorTextView: NSTextView {
  var commandHandler: ((GrowingTextEditor.Command) -> Bool)?
  var focusHandler: ((Bool) -> Void)?
  var placeholder = "" {
    didSet { if placeholder != oldValue { needsDisplay = true } }
  }
  var placeholderAttributes: [NSAttributedString.Key: Any] = [:]

  /// La hauteur d'une ligne de la police courante, interligne non compris.
  var lineHeight: CGFloat {
    guard let font, let layoutManager else { return 20 }
    return ceil(layoutManager.defaultLineHeight(for: font))
  }

  /// La hauteur qu'occupe le texte composé sur cette largeur.
  func usedHeight(forWidth width: CGFloat) -> CGFloat {
    guard let layoutManager, let textContainer else { return lineHeight }
    if abs(bounds.width - width) > 0.5 {
      setFrameSize(NSSize(width: width, height: bounds.height))
    }
    layoutManager.ensureLayout(for: textContainer)
    return layoutManager.usedRect(for: textContainer).height
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    let origin = NSPoint(
      x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
      y: textContainerInset.height
    )
    NSAttributedString(string: placeholder, attributes: placeholderAttributes).draw(at: origin)
  }

  override func becomeFirstResponder() -> Bool {
    let ok = super.becomeFirstResponder()
    if ok { focusHandler?(true) }
    return ok
  }

  override func resignFirstResponder() -> Bool {
    let ok = super.resignFirstResponder()
    if ok { focusHandler?(false) }
    return ok
  }

  override func keyDown(with event: NSEvent) {
    // Échap : `NSTextView` en ferait une complétion ; la page veut quitter.
    if event.keyCode == 53, commandHandler?(.escape) == true { return }
    super.keyDown(with: event)
  }

  override func doCommand(by selector: Selector) {
    switch selector {
    case #selector(insertNewline(_:)):
      // ⇧Entrée insère une ligne ; Entrée seule revient à la page (envoyer,
      // ou choisir dans le menu « @ »).
      let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
      if flags.contains(.shift) || commandHandler?(.send) != true {
        super.doCommand(by: selector)
      }
    case #selector(moveUp(_:)):
      if commandHandler?(.moveUp) != true { super.doCommand(by: selector) }
    case #selector(moveDown(_:)):
      if commandHandler?(.moveDown) != true { super.doCommand(by: selector) }
    case #selector(insertTab(_:)):
      if commandHandler?(.tab) != true { super.doCommand(by: selector) }
    default:
      super.doCommand(by: selector)
    }
  }
}
