import SwiftUI
import CorrespondanceCore

/// Un sondage dans le fil : la question, les réponses, et ce qu'on a voté.
///
/// La même vue sur le Mac et sur l'iPhone — un sondage se lit pareil partout.
/// Elle ne sait rien du réseau : `onVote` porte la voix jusqu'au store, qui
/// sait quel salon et quelle forme d'event (MSC3381) employer.
public struct PollView: View {
  public let poll: Poll
  public let theme: WritingTheme
  public var typeface: WritingTypeface = .quattro
  public var isFromMe: Bool = false
  /// Appelé avec l'identifiant de la réponse touchée. `nil` = sondage en
  /// lecture seule (un résultat de recherche, un aperçu).
  public var onVote: ((String) -> Void)?

  public init(
    poll: Poll,
    theme: WritingTheme,
    typeface: WritingTypeface = .quattro,
    isFromMe: Bool = false,
    onVote: ((String) -> Void)? = nil
  ) {
    self.poll = poll
    self.theme = theme
    self.typeface = typeface
    self.isFromMe = isFromMe
    self.onVote = onVote
  }

  private var ink: Color { isFromMe ? theme.bubbleOutInk : theme.ink }
  private var inkSoft: Color { isFromMe ? theme.bubbleOutInk.opacity(0.75) : theme.inkSecondary }
  private var accent: Color { isFromMe ? theme.bubbleOutInk : theme.accent }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 5) {
        Image(systemName: "chart.bar.doc.horizontal")
          .font(.system(size: 10, weight: .semibold))
        Text(poll.maxSelections > 1 ? "Sondage · plusieurs choix" : "Sondage")
          .font(Typography.meta(typeface))
      }
      .foregroundStyle(inkSoft)

      Text(poll.question)
        .font(Typography.body(typeface))
        .foregroundStyle(ink)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 5) {
        ForEach(poll.answers) { answer in
          answerRow(answer)
        }
      }

      Text(poll.summaryFR())
        .font(Typography.meta(typeface))
        .foregroundStyle(inkSoft)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: 320, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(isFromMe ? theme.bubbleOut : theme.bubbleIn)
    )
  }

  @ViewBuilder
  private func answerRow(_ answer: Poll.Answer) -> some View {
    let voted = poll.hasVoted(answer.id)
    let fraction = poll.showsResults ? poll.fraction(of: answer.id) : 0
    Button {
      onVote?(answer.id)
    } label: {
      ZStack(alignment: .leading) {
        // La barre de résultat, DERRIÈRE le texte : c'est le fond qui se
        // remplit, pas une jauge à côté qu'il faudrait lire séparément.
        GeometryReader { geometry in
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(accent.opacity(voted ? 0.30 : 0.16))
            .frame(width: max(0, geometry.size.width * fraction))
        }
        HStack(spacing: 7) {
          Image(systemName: voted ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 12))
            .foregroundStyle(voted ? accent : inkSoft)
          Text(answer.text)
            .font(Typography.body(typeface))
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 6)
          if poll.showsResults {
            Text("\(poll.count(of: answer.id))")
              .font(Typography.meta(typeface))
              .foregroundStyle(inkSoft)
              .monospacedDigit()
          }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(theme.edge.opacity(0.7), lineWidth: 0.8)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(onVote == nil || poll.isClosed)
    .accessibilityLabel(
      poll.showsResults
        ? "\(answer.text), \(poll.count(of: answer.id)) vote(s)"
        : answer.text
    )
    .accessibilityAddTraits(voted ? [.isSelected, .isButton] : .isButton)
  }
}
