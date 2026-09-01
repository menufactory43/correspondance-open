import CorrespondanceCore
import CorrespondanceUI
import SwiftUI
import UIKit

/// « Sélectionner » sur un message : le texte, seul sur la page, avec les
/// poignées de sélection du système pour n'en prendre que quelques mots.
/// `Text.textSelection(.enabled)` ne sait pas faire ça sur iOS — il copie tout
/// ou rien — d'où un `UITextView` en lecture seule. Tout est sélectionné à
/// l'ouverture : on resserre, on copie, on ferme.
struct SelectTextSheet: View {
  let text: String

  @Environment(ThemePreferences.self) private var themes
  @Environment(\.dismiss) private var dismiss

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  var body: some View {
    NavigationStack {
      SelectableText(text: text, typeface: typeface, theme: theme)
        .padding(.horizontal, Spacing.md)
        .background(theme.paper.ignoresSafeArea())
        .navigationTitle("Sélectionner")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) { Button("Fermer") { dismiss() } }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Tout copier") {
              Platform.copyToPasteboard(text)
              dismiss()
            }
          }
        }
        .toolbarBackground(theme.paper, for: .navigationBar)
    }
    .tint(theme.accent)
    .presentationDetents([.medium, .large])
  }
}

/// Le `UITextView` derrière la feuille : même police et même corps que la
/// bulle, non éditable, sélectionnable, présélectionné en entier.
private struct SelectableText: UIViewRepresentable {
  let text: String
  let typeface: WritingTypeface
  let theme: WritingTheme

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = true
    view.backgroundColor = .clear
    view.textContainerInset = UIEdgeInsets(top: Spacing.sm, left: 0, bottom: Spacing.md, right: 0)
    view.textContainer.lineFragmentPadding = 0
    view.dataDetectorTypes = [.link, .phoneNumber]
    view.accessibilityIdentifier = "Texte à sélectionner"
    apply(to: view)
    // Tout sélectionné d'entrée : le geste attendu est de resserrer les poignées,
    // pas de partir d'un curseur perdu au milieu du texte.
    DispatchQueue.main.async {
      view.becomeFirstResponder()
      view.selectAll(nil)
    }
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    apply(to: view)
  }

  private func apply(to view: UITextView) {
    if view.text != text { view.text = text }
    let size = Typography.bubbleSize()
    let font = UIFont(name: typeface.postScriptRegular, size: size)
      ?? UIFont.systemFont(ofSize: size)
    view.font = font
    view.textColor = UIColor(theme.ink)
    view.tintColor = UIColor(theme.accent)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = theme.bubbleLineSpacing(forBodySize: size)
    view.typingAttributes = [.font: font, .foregroundColor: UIColor(theme.ink), .paragraphStyle: paragraph]
    let range = NSRange(location: 0, length: (view.text as NSString).length)
    view.textStorage.addAttributes([.paragraphStyle: paragraph], range: range)
  }
}
