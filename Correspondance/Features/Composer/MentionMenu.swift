import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

/// Le menu « @ » : posé au-dessus du champ, il liste les gens du fil et se
/// pilote au clavier (↑ ↓, Entrée ou Tab pour choisir, Échap pour le ranger).
/// Le même modifieur sert au composer de la boîte et à la feuille du Focus.
struct MentionField: ViewModifier {
  @Binding var text: String
  /// Le fil dont on cite les gens. `nil` = aucun fil ouvert, pas de menu.
  var session: ConversationSession?
  var theme: WritingTheme
  var font: Font
  /// L'interligne du champ : le surlignage se pose DERRIÈRE son texte, il doit
  /// donc être composé exactement comme lui.
  var lineSpacing: CGFloat

  @Environment(InboxStore.self) private var store
  @State private var selectedIndex = 0
  /// Mention écartée d'un Échap : le menu reste rangé tant qu'elle ne change pas.
  @State private var dismissedToken: MentionParser.Token?

  private var token: MentionParser.Token? { MentionParser.activeToken(in: text) }

  private var matches: [MentionCandidate] {
    guard let token, let session else { return [] }
    return MentionParser.matches(session.mentionCandidates, query: token.query)
  }

  private var isVisible: Bool {
    token != nil && token != dismissedToken && !matches.isEmpty
  }

  func body(content: Content) -> some View {
    content
      // La mention posée se voit dans le champ : `TextField` ne prend que du
      // texte nu, la bande d'accent se glisse donc derrière lui.
      .background(alignment: .topLeading) {
        MentionUnderlay(
          text: text,
          names: session?.mentionCandidates.map(\.name) ?? [],
          tint: theme.accent.opacity(0.16),
          font: font,
          lineSpacing: lineSpacing
        )
      }
      .onKeyPress(.upArrow) { step(-1) }
      .onKeyPress(.downArrow) { step(1) }
      .onKeyPress(.return) { pick() }
      .onKeyPress(.tab) { pick() }
      .onKeyPress(.escape) {
        guard isVisible else { return .ignored }
        dismissedToken = token
        return .handled
      }
      .onChange(of: matches.map(\.id)) { _, _ in selectedIndex = 0 }
      // La liste dépend du fil et de ceux qui y ont parlé : on la refait quand
      // l'un ou l'autre change, pas à chaque frappe.
      .task(id: "\(session?.conversationID ?? "")|\(session?.messages.count ?? 0)") {
        guard let session else { return }
        await store.refreshMentionCandidates(for: session)
      }
      .overlay(alignment: .topLeading) {
        if isVisible {
          MentionMenuView(
            candidates: matches,
            selectedIndex: selectedIndex,
            theme: theme,
            font: font,
            onHover: { selectedIndex = $0 },
            onPick: choose
          )
          // Au-dessus du champ, jamais dessous : en bas de fenêtre, il n'y a pas de place.
          .offset(y: -(MentionMenuView.height(for: matches.count) + 8))
          .accessibilityAddTraits(.isModal)
        }
      }
  }

  private func step(_ delta: Int) -> KeyPress.Result {
    guard isVisible else { return .ignored }
    let count = matches.count
    selectedIndex = ((selectedIndex + delta) % count + count) % count
    return .handled
  }

  private func pick() -> KeyPress.Result {
    guard isVisible, matches.indices.contains(selectedIndex) else { return .ignored }
    choose(matches[selectedIndex])
    return .handled
  }

  private func choose(_ candidate: MentionCandidate) {
    guard let token else { return }
    text = MentionParser.insert(candidate, replacing: token, in: text)
  }
}

extension View {
  /// Taper « @ » dans ce champ ouvre le menu des gens du fil ouvert.
  func mentionMenu(
    text: Binding<String>, session: ConversationSession?, theme: WritingTheme, font: Font,
    lineSpacing: CGFloat
  ) -> some View {
    modifier(
      MentionField(text: text, session: session, theme: theme, font: font, lineSpacing: lineSpacing)
    )
  }
}

struct MentionMenuView: View {
  var candidates: [MentionCandidate]
  var selectedIndex: Int
  var theme: WritingTheme
  var font: Font
  var onHover: (Int) -> Void
  var onPick: (MentionCandidate) -> Void

  private static let rowHeight: CGFloat = 40
  private static let visibleRows = 7

  /// Hauteur du menu : ses lignes, sept au plus, plus les marges.
  static func height(for count: Int) -> CGFloat {
    min(CGFloat(count), CGFloat(visibleRows)) * (rowHeight + 2) + 10
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(showsIndicators: false) {
        VStack(spacing: 2) {
          ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
            row(candidate, isSelected: index == selectedIndex)
              .id(candidate.id)
              .onHover { if $0 { onHover(index) } }
              .onTapGesture { onPick(candidate) }
          }
        }
        .padding(6)
      }
      .frame(height: Self.height(for: candidates.count))
      .onChange(of: selectedIndex) { _, index in
        guard candidates.indices.contains(index) else { return }
        proxy.scrollTo(candidates[index].id, anchor: nil)
      }
    }
    .frame(width: 280)
    .glassSurface(
      cornerRadius: 16,
      fallbackFill: theme.paperSecondary,
      border: theme.edge
    )
    .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
    .accessibilityLabel("Mentionner quelqu'un")
  }

  private func row(_ candidate: MentionCandidate, isSelected: Bool) -> some View {
    HStack(spacing: 10) {
      ConversationAvatarView(
        conversation: candidate.avatar, size: 28, theme: theme, showsNetworkBadge: false
      )
      Text(candidate.name)
        .font(font)
        .foregroundStyle(isSelected ? theme.paper : theme.ink)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .frame(height: Self.rowHeight)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(isSelected ? theme.accent : Color.clear)
    )
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}
