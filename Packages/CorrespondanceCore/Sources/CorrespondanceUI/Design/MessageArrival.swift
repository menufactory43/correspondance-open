import SwiftUI
import CorrespondanceCore

/// Comment un message arrive dans le fil.
///
/// L'Inbox n'a pas le choix : ses bulles prennent l'encre. La page du mode
/// Focus, elle, peut se permettre la plume — c'est de la prose, pas des bulles.
public enum MessageArrival: String, CaseIterable, Identifiable, Codable, Sendable {
  /// L'encre prend : le texte se précise depuis un flou.
  case encre
  /// La plume trace : le texte se dévoile de gauche à droite.
  case plume

  public var id: String { rawValue }

  public var labelFR: String {
    switch self {
    case .encre: "Encre"
    case .plume: "Plume"
    }
  }

  public var subtitleFR: String {
    switch self {
    case .encre: "Le texte se précise depuis un flou"
    case .plume: "Le texte se trace de gauche à droite"
    }
  }

  /// Chaque geste a sa durée : l'encre prend vite, la plume prend son temps.
  public var animation: Animation {
    switch self {
    case .encre: .smooth(duration: 0.52)
    case .plume: .easeOut(duration: 0.7)
    }
  }
}

/// L'encre prend sur le papier : le message se précise depuis un flou au lieu
/// d'être posé d'un bloc.
public struct InkArrival: ViewModifier, @preconcurrency Animatable {
  public var progress: Double

  public var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  public func body(content: Content) -> some View {
    let remaining = 1 - min(max(progress, 0), 1)
    return content
      .blur(radius: remaining * 6)
      .opacity(1 - remaining)
      .offset(y: remaining * 5)
  }

  public init(progress: Double) {
    self.progress = progress
  }
}

/// La plume trace : un dégradé balaie le texte de gauche à droite, bord flou
/// en tête pour que la lettre se forme au lieu d'être découpée.
public struct QuillArrival: ViewModifier, @preconcurrency Animatable {
  public var progress: Double

  public var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  public func body(content: Content) -> some View {
    // La tête de plume dépasse le bord droit en fin de course : sans ce
    // dépassement, la dernière lettre garderait le dégradé pour elle.
    let head = min(max(progress, 0), 1) * 1.25
    let front = min(head, 1)
    let tail = min(max(head - 0.18, 0), front)

    return content.mask(alignment: .leading) {
      LinearGradient(
        stops: [
          .init(color: .black, location: 0),
          .init(color: .black, location: tail),
          .init(color: .clear, location: front),
          .init(color: .clear, location: 1)
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
    }
  }

  public init(progress: Double) {
    self.progress = progress
  }
}

/// Le geste, appliqué au message lui-même.
///
/// Une `LazyVStack` ne joue pas les transitions d'insertion — ses lignes
/// naissent à la demande, hors de toute transaction. C'est donc le message qui
/// se charge de son arrivée, à la seconde où il paraît.
public struct MessageArrivalEffect: ViewModifier {
  public let gesture: MessageArrival
  public let isFresh: Bool
  public let isEnabled: Bool

  @State private var progress: Double

  public init(gesture: MessageArrival, isFresh: Bool, isEnabled: Bool) {
    self.gesture = gesture
    self.isFresh = isFresh
    self.isEnabled = isEnabled
    // La ligne naît à l'instant de l'insertion : sa valeur initiale suffit à
    // dire si elle doit se tracer ou paraître déjà posée.
    _progress = State(initialValue: isFresh && isEnabled ? 0 : 1)
  }

  public func body(content: Content) -> some View {
    Group {
      switch gesture {
      case .encre: content.modifier(InkArrival(progress: progress))
      case .plume: content.modifier(QuillArrival(progress: progress))
      }
    }
    .onAppear {
      guard progress < 1 else { return }
      withAnimation(gesture.animation) { progress = 1 }
    }
  }
}

public extension View {
  /// `isFresh` : ce message vient d'arriver, il n'était pas là il y a un
  /// instant. Tout le reste du fil paraît posé, sans cérémonie.
  public func messageArrival(
    _ gesture: MessageArrival,
    isFresh: Bool,
    isEnabled: Bool
  ) -> some View {
    modifier(MessageArrivalEffect(gesture: gesture, isFresh: isFresh, isEnabled: isEnabled))
  }
}
