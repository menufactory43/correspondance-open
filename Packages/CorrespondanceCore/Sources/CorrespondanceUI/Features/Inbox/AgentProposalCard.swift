import SwiftUI
import CorrespondanceCore

/// Le brouillon de « cc » dans le fil : ce qu'il enverrait si on le laissait.
///
/// La même carte sur le Mac et sur l'iPhone — un brouillon se relit pareil
/// partout. Elle ne sait rien du réseau : les trois gestes remontent au store,
/// qui sait dans quel salon envoyer et quoi masquer.
///
/// Le ton est celui d'un brouillon, pas d'une alerte : le papier creusé du
/// thème, un liseré en pointillés (rien n'est encore posé), l'encre secondaire
/// pour l'en-tête. Aucune couleur criarde — l'accent ne sert qu'au verbe qui
/// engage, « Envoyer ».
public struct AgentProposalCard: View {
  public let proposal: AgentProposal
  public let theme: WritingTheme
  public var typeface: WritingTypeface = .quattro
  /// Le texte part comme MON message, par le chemin d'envoi normal.
  public var onSend: (() -> Void)?
  /// Le texte descend dans le composer, la proposition disparaît.
  public var onEdit: (() -> Void)?
  /// La proposition disparaît, sans rien envoyer.
  public var onIgnore: (() -> Void)?

  public init(
    proposal: AgentProposal,
    theme: WritingTheme,
    typeface: WritingTypeface = .quattro,
    onSend: (() -> Void)? = nil,
    onEdit: (() -> Void)? = nil,
    onIgnore: (() -> Void)? = nil
  ) {
    self.proposal = proposal
    self.theme = theme
    self.typeface = typeface
    self.onSend = onSend
    self.onEdit = onEdit
    self.onIgnore = onIgnore
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 5) {
        Image(systemName: "pencil.line")
          .font(.system(size: 10, weight: .semibold))
        Text(proposal.headerFR)
          .font(Typography.meta(typeface))
        Spacer(minLength: 0)
        // Dit ce que la carte est, pour qu'on ne la croie jamais partie.
        Text("visible ici seulement")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkTertiary)
      }
      .foregroundStyle(theme.inkSecondary)

      Text(proposal.text)
        .font(Typography.bubble(typeface))
        .lineSpacing(theme.bubbleLineSpacing(forBodySize: Typography.bubbleSize()))
        .foregroundStyle(theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 6) {
        action("Envoyer", systemImage: "paperplane", isPrimary: true, run: onSend)
        action("Modifier", systemImage: "pencil", isPrimary: false, run: onEdit)
        action("Ignorer", systemImage: "xmark", isPrimary: false, run: onIgnore)
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: 340, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(theme.paperSecondary)
    )
    .overlay(
      // En pointillés : rien n'est encore dit.
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          theme.edge,
          style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(proposal.headerFR) : \(proposal.text)")
  }

  @ViewBuilder
  private func action(
    _ label: String,
    systemImage: String,
    isPrimary: Bool,
    run: (() -> Void)?
  ) -> some View {
    Button {
      run?()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: systemImage)
          .font(.system(size: 10, weight: .semibold))
        Text(label)
          .font(Typography.meta(typeface))
      }
      .foregroundStyle(isPrimary ? theme.accent : theme.inkSecondary)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isPrimary ? theme.accent.opacity(0.14) : theme.paper)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(theme.edge.opacity(isPrimary ? 0 : 0.7), lineWidth: 0.8)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(run == nil)
    .accessibilityLabel(label)
  }
}
