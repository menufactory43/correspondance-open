import CorrespondanceCore
import SwiftUI

/// Les pastilles de réaction, posées dans le coin de la bulle.
///
/// Messages et WhatsApp les font CHEVAUCHER le bord : accrochées au coin, elles
/// appartiennent à la bulle, alors qu'une rangée posée dessous flottait entre
/// deux messages sans qu'on sache lequel elle décorait. D'où le liseré de la
/// couleur du papier — c'est lui qui détache la pastille de la bulle qu'elle
/// mord — et le `padding(.bottom:)` que l'appelant réserve pour le débord.
public struct ReactionPills: View {
  private let reactions: [MessageReaction]
  private let theme: WritingTheme
  private let typeface: WritingTypeface
  private let emojiSize: CGFloat
  private let onTap: ((String) -> Void)?
  private let showsSendersOnLongPress: Bool

  /// Le débord sous la bulle, que l'appelant doit réserver.
  public static let overhang: CGFloat = 10

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// La pastille dont on veut savoir qui l'a posée (appui long, au doigt).
  @State private var inspected: MessageReaction?
  /// Ce qui déclenche la petite secousse : un geste À MOI, pas une réaction
  /// qui arrive du réseau — celle-là ne doit rien faire vibrer.
  @State private var taps = 0

  public init(
    reactions: [MessageReaction],
    theme: WritingTheme,
    typeface: WritingTypeface = .quattro,
    emojiSize: CGFloat = 12,
    showsSendersOnLongPress: Bool = false,
    onTap: ((String) -> Void)? = nil
  ) {
    self.reactions = reactions
    self.theme = theme
    self.typeface = typeface
    self.emojiSize = emojiSize
    self.showsSendersOnLongPress = showsSendersOnLongPress
    self.onTap = onTap
  }

  public var body: some View {
    HStack(spacing: 4) {
      ForEach(reactions) { reaction in
        pill(reaction)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.45), value: reactions)
    .sensoryFeedback(.selection, trigger: taps)
    .sheet(item: $inspected) { reaction in
      sendersSheet(reaction)
    }
  }

  private func pill(_ reaction: MessageReaction) -> some View {
    Button {
      taps += 1
      onTap?(reaction.emoji)
    } label: {
      HStack(spacing: 3) {
        Text(reaction.emoji).font(.system(size: emojiSize))
        if reaction.count > 1 {
          Text("\(reaction.count)")
            .font(Typography.meta(typeface))
            .foregroundStyle(theme.inkSecondary)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(theme.paperSecondary))
      .overlay(Capsule().stroke(reaction.isMine ? theme.accent : theme.edge, lineWidth: 1))
      // Le liseré de papier : sans lui, une pastille qui mord la bulle se
      // confond avec elle. C'est le trait que Messages dessine aussi.
      .overlay(Capsule().stroke(theme.paper, lineWidth: 2).padding(-1.5))
    }
    .buttonStyle(.plain)
    .help(reaction.senders.isEmpty ? reaction.emoji : reaction.senders.joined(separator: ", "))
    .accessibilityLabel("\(reaction.emoji), \(reaction.count)")
    .onLongPressGesture {
      guard showsSendersOnLongPress, !reaction.senders.isEmpty else { return }
      inspected = reaction
    }
  }

  /// Au doigt, l'infobulle du Mac n'existe pas : qui a réagi tient dans une
  /// feuille de la hauteur de sa liste.
  private func sendersSheet(_ reaction: MessageReaction) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("\(reaction.emoji)  \(reaction.count)")
        .font(Typography.body(typeface, size: 20))
        .foregroundStyle(theme.ink)
      ForEach(reaction.senders, id: \.self) { sender in
        Text(sender)
          .font(Typography.body(typeface, size: 16))
          .foregroundStyle(theme.inkSecondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(theme.paper.ignoresSafeArea())
    .presentationDetents([.height(CGFloat(reaction.senders.count) * 24 + 96)])
  }
}
