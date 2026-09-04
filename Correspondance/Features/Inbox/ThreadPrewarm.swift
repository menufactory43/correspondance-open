import Foundation
import CorrespondanceCore
import CorrespondanceUI

/// Ce qu'une bulle calcule en se construisant et qui n'a rien à faire sur le
/// fil principal : la langue du texte (`NLLanguageRecognizer`, pour le bouton
/// « Traduire ») et ses liens (`NSDataDetector`). Les deux sont mémorisés par
/// texte ; ici on remplit ces mémos EN AVANCE, sur un autre cœur, dès que les
/// messages d'un fil sont connus — pendant qu'AppKit monte la fenêtre au
/// lancement, ou pendant que la queue du fil se peint à la bascule.
///
/// Mesuré au lancement, fil de 300 messages : 146 ms de langue et 78 ms de
/// liens sur le fil principal, dans le bloc qui monte le reste du fil après
/// la première frame. Ce bloc gelait la fenêtre à peine apparue.
@MainActor
enum ThreadPrewarm {
  /// Les textes déjà envoyés au préchauffage : on ne repasse pas dessus.
  private static var warmed: Set<String> = []
  /// Le dernier préchauffage lancé ; `ready` l'attend, un temps borné.
  private static var latest: Task<Void, Never>?

  static func schedule(_ messages: [ChatMessage]) {
    var languages: [String] = []
    var links: [String] = []
    for message in messages {
      let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, warmed.insert(text).inserted else { continue }
      links.append(text)
      // La langue ne se demande que là où la bulle offrira « Traduire ».
      if !message.isFromMe, !message.isRetracted, message.attachments.isEmpty {
        languages.append(text)
      }
    }
    guard !links.isEmpty else { return }
    // Borne grossière, comme le mémo des liens.
    if warmed.count > 5_000 { warmed.removeAll(keepingCapacity: true) }
    latest = Task.detached(priority: .userInitiated) {
      for text in languages { _ = TextTranslator.language(of: text) }
      await LinkedText.prewarm(links)
    }
  }

  /// Attend le préchauffage en cours, sans jamais retenir le fil au-delà de
  /// `limit` : un fil qui monte avec des mémos froids est lent, pas faux.
  static func ready(within limit: Duration) async {
    guard let task = latest else { return }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await task.value }
      group.addTask { try? await Task.sleep(for: limit) }
      await group.next()
      group.cancelAll()
    }
  }
}
