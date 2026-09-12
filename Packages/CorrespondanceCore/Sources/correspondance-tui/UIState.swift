import CorrespondanceCore
import CorrespondanceTerminal
import Foundation

/// Ce que l'écran retient et que le magasin n'a pas à savoir : quel panneau a
/// la main, où en est le défilement, ce que le composer contient à l'instant.
struct UIState {
  enum Mode: Equatable { case focus, inbox }
  enum Pane: Equatable { case list, thread }

  var mode: Mode = .focus
  var pane: Pane = .list
  var terminalHasFocus = true

  // MARK: Liste

  /// La ligne sélectionnée, par identifiant : la liste peut se réordonner sous
  /// le curseur sans qu'il saute ailleurs.
  var listSelectionID: String?
  /// Première ligne visible de la liste.
  var listTop = 0
  /// Rang de la sélection à la dernière image : si sa ligne disparaît (archivée),
  /// la sélection glisse sur la voisine au lieu de remonter en tête.
  var listLastIndex = 0
  var listCount = 0
  var listPageSize = 10
  /// Où chaque ligne a été dessinée, pour la souris.
  var listRowFrames: [(Rect, String)] = []
  /// Le fil de Focus déjà ouvert : ne pas le rouvrir à chaque image.
  var lastOpenedFocusID: String?

  // MARK: Fil

  struct ThreadViewport: Equatable {
    /// Le message sous le curseur ; `nil` = on suit le bas du fil.
    var cursorMessageID: String?
    /// Lignes défilées depuis le bas ; 0 = collé au dernier message.
    var scrollFromBottom = 0
    /// De quoi garder la vue immobile quand un message arrive pendant qu'on lit plus haut.
    var lastTotalLines = 0
    var lastMessageID: String?
  }

  var viewports: [String: ThreadViewport] = [:]
  var threadPageSize = 20
  /// La ligne d'écran de chaque ligne de message, pour la souris.
  var threadLineFrames: [(Int, String)] = []
  /// Les fils dont on vient de demander l'historique.
  var olderRequested: Set<String> = []

  // MARK: Composer

  var isComposing = false
  var composer = LineEditor(allowsNewlines: true)
  /// Le fil auquel le composer écrit.
  var composerConversationID: String?
  /// Le dernier texte échangé avec le magasin : ce qui diffère vient de lui
  /// (un envoi qui vide, une correction qui remplit).
  var composerSynced = ""
  /// La largeur du texte du composer à la dernière image : ↑/↓ s'y déplacent.
  var composerWidth = 60

  // MARK: Surimpressions

  enum Overlay {
    case help
    case search(SearchState)
    case reactions(conversationID: String, messageID: String, index: Int)
    case reminder(conversationID: String, index: Int)
    case forward(ForwardState)
    case confirm(ConfirmState)
    case attach(conversationID: String, editor: LineEditor, error: String?)
    case poll(conversationID: String, messageID: String, index: Int)
    case filters(index: Int)
  }

  var overlay: Overlay?

  struct SearchState {
    var editor = LineEditor()
    var index = 0
    var results: [SearchResult] = []
    var query = ""
  }

  struct SearchResult: Equatable {
    var conversationID: String
    var title: String
    var network: MessageNetwork
    var excerpt: String
  }

  struct ForwardState {
    var conversationID: String
    var messageID: String
    var editor = LineEditor()
    var index = 0
  }

  struct ConfirmState {
    var title: String
    var detail: String
    var action: ConfirmAction
  }

  enum ConfirmAction {
    case deleteEverywhere(conversationID: String, messageID: String)
    case archiveAllRead
    case reload
    case signOut
    case declineRequest(conversationID: String)
  }

  // MARK: Connexion

  struct LoginForm {
    var code = LineEditor()
    var homeserver = LineEditor()
    var user = LineEditor()
    var password = LineEditor()
    var field = 0
    var didPrefill = false
    static let fieldCount = 4

    subscript(field index: Int) -> LineEditor {
      get {
        switch index {
        case 0: code
        case 1: homeserver
        case 2: user
        default: password
        }
      }
      set {
        switch index {
        case 0: code = newValue
        case 1: homeserver = newValue
        case 2: user = newValue
        default: password = newValue
        }
      }
    }
  }

  var login = LoginForm()

  // MARK: Barre d'état

  struct Toast {
    var text: String
    var isError: Bool
    var until: Date
  }

  var toast: Toast?

  /// ^C une fois dans le composer vide : on prévient ; deux fois : on quitte.
  var pendingQuit = false
}
