import SwiftUI
import CorrespondanceCore
import CorrespondanceUI

struct CorrespondanceCommands: Commands {
  var store: InboxStore
  /// Les préférences d'ambiance : le menu Présentation y règle l'échelle de
  /// lecture. Passées comme le store — un `Commands` n'est pas une vue, il ne
  /// lit pas l'environnement.
  var themes: ThemePreferences

  /// Le fil qu'un ⌘⇧D vise : celui de la fenêtre détachée au premier plan,
  /// sinon celui que lit l'inbox.
  private var detachedFront: String? { store.frontDetachedConversationID }

  private var detachTitle: String {
    detachedFront != nil ? "Ramener dans l’inbox" : "Détacher la conversation"
  }

  private var pinTitle: String {
    guard let id = detachedFront, store.isPinnedDetached(id) else { return "Épingler au-dessus" }
    return "Ne plus épingler"
  }

  /// ⌘E vise ce qu'on a sous les yeux : la fenêtre détachée si elle est
  /// devant, le fil de l'inbox sinon.
  private var archiveTarget: String? {
    detachedFront ?? store.selectedConversationID
  }

  private var archiveTitle: String {
    guard let id = archiveTarget else { return "Archiver" }
    return store.isArchived(id) ? "Désarchiver" : "Archiver"
  }

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Nouvelle conversation") {
        store.presentNewConversation()
      }
      .keyboardShortcut("n", modifiers: [.command])

      // ⌘⇧N est pris par la note à soi : le groupe passe en ⌥⌘N. L'entrée
      // disparaît quand aucun pont branché ne sait créer de groupe — mieux
      // vaut pas de menu qu'un menu qui échoue par construction.
      Button("Nouveau groupe…") {
        store.isPresentingNewGroup = true
      }
      .keyboardShortcut("n", modifiers: [.command, .option])
      .disabled(!store.canCreateGroup)

      // ⌘R appartient à « Répondre en citant » (comme Beeper) : l'actualisation
      // manuelle, rare depuis que les trois réseaux syncent tout seuls, passe en ⌘⇧R.
      Button("Actualiser l’inbox") {
        Task { @MainActor in
          await store.refresh()
        }
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
    }

    CommandMenu("Inbox") {
      // ⌘⇧F revient au transfert (comme Beeper) : le mode Focus passe en ⌘⇧O.
      Button("Mode Focus") {
        store.setMode(store.mode == .focus ? .inbox : .focus)
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])

      Divider()

      // Rail de réseaux : ⌘1 = Tous, puis l'ordre de `MessageNetwork`.
      ForEach(Array(NetworkRailView.slots.enumerated()), id: \.offset) { index, network in
        NetworkFilterCommand(store: store, network: network, position: index + 1)
      }

      Divider()

      Button("Répondre en citant") {
        store.replyToSelectedMessage()
      }
      .keyboardShortcut("r", modifiers: [.command])

      // ⌘⇧R est pris par l'actualisation : le « quick react » de Beeper passe en ⌘⌥R.
      Button("Réagir 👍") {
        Task { @MainActor in await store.quickReactToSelectedMessage() }
      }
      .keyboardShortcut("r", modifiers: [.command, .option])

      // Même touche que Beeper (EDIT_MESSAGE ⌘T) : le composer passe en mode
      // correction sur la bulle visée, là où le réseau sait modifier.
      Button("Modifier le message") {
        store.editSelectedMessage()
      }
      .keyboardShortcut("t", modifiers: [.command])

      // FORWARD_MESSAGES ⌘⇧F chez Beeper.
      Button("Transférer…") {
        store.forwardSelectedMessage()
      }
      .keyboardShortcut("f", modifiers: [.command, .shift])

      // Même touche que Beeper (TOGGLE_FILTER_UNREAD ⌘⇧Y), élargie à toute la
      // rangée de pilules : « non lus » n'est qu'un filtre parmi cinq.
      Button(store.isFilterBarVisible ? "Masquer les filtres" : "Filtrer la liste") {
        store.toggleFilterBar()
      }
      .keyboardShortcut("y", modifiers: [.command, .shift])

      Button("Rechercher dans le fil") {
        store.toggleThreadSearch()
      }
      .keyboardShortcut("f", modifiers: [.command])

      // Même touche que Beeper (SCHEDULE_MESSAGE ⌘⇧L).
      Button("Envoyer plus tard…") {
        store.toggleSendLaterPicker()
      }
      .keyboardShortcut("l", modifiers: [.command, .shift])

      Divider()

      Button("Conversation suivante") {
        Task { @MainActor in await store.focusNext() }
      }
      .keyboardShortcut(.downArrow, modifiers: [.command])

      Button("Conversation précédente") {
        Task { @MainActor in await store.focusPrevious() }
      }
      .keyboardShortcut(.upArrow, modifiers: [.command])

      Button(archiveTitle) {
        Task { @MainActor in
          guard let id = archiveTarget else { return }
          await store.toggleArchived(conversationID: id)
        }
      }
      .keyboardShortcut("e", modifiers: [.command])

      // ⌘⇧E ouvre déjà la vue « Archivés » : le balayage prend ⌥⌘E, libre.
      Button("Archiver tout ce qui est lu…") {
        store.presentArchiveAllRead()
      }
      .keyboardShortcut("e", modifiers: [.command, .option])
      .disabled(store.readArchivableConversations.isEmpty)

      Button(store.isSelectionMode ? "Quitter la sélection" : "Sélectionner plusieurs fils") {
        store.toggleSelectionMode()
      }

      Button(store.isShowingArchived ? "Retour à l’inbox" : "Voir les archivés") {
        store.setShowingArchived(!store.isShowingArchived)
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])

      // Se laisser un mot : un salon du Relais dont on est le seul membre,
      // donc le même fil sur le Mac et sur l'iPhone.
      Button("Note à soi") {
        Task { @MainActor in await store.openSelfNote() }
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(!store.isMatrixConnected)

      Button(store.isShowingScheduled ? "Retour à l’inbox" : "Voir les programmés") {
        store.setShowingScheduled(!store.isShowingScheduled)
      }
      .disabled(!store.isShowingScheduled && store.scheduledMessages.isEmpty)

      // Le geste Focus : je réponds, j'archive, je passe au suivant.
      // Commande de menu plutôt que `onKeyPress` : le raccourci vaut alors dans
      // le composer de l'Inbox *et* dans l'éditeur pleine page du mode Focus.
      Button("Envoyer et archiver") {
        Task { @MainActor in await store.sendDraftAndArchive() }
      }
      .keyboardShortcut(.return, modifiers: [.command])
    }

    // Le menu Présentation : la taille du texte. ⌘1…⌘9 appartiennent déjà au
    // rail des réseaux, ⌘0 était libre — il revient donc au « 100 % », comme
    // partout ailleurs sur le système.
    CommandGroup(after: .toolbar) {
      Divider()

      Button("Agrandir le texte") {
        themes.nudgeTypeScale(+1)
      }
      .keyboardShortcut("+", modifiers: [.command])
      .disabled(themes.typeScale >= ThemePreferences.typeScaleRange.upperBound - 0.001)

      Button("Réduire le texte") {
        themes.nudgeTypeScale(-1)
      }
      .keyboardShortcut("-", modifiers: [.command])
      .disabled(themes.typeScale <= ThemePreferences.typeScaleRange.lowerBound + 0.001)

      Button("Taille normale (\(themes.typeScaleLabelFR))") {
        themes.resetTypeScale()
      }
      .keyboardShortcut("0", modifiers: [.command])
      .disabled(themes.isTypeScaleDefault)

      Divider()
    }

    CommandGroup(after: .windowArrangement) {
      Divider()

      // Une conversation n'a aucune raison de rester enfermée dans la liste.
      Button(detachTitle) {
        if let id = detachedFront {
          Task { @MainActor in await store.reattach(conversationID: id) }
        } else if let id = store.selectedConversationID {
          store.detach(conversationID: id)
        }
      }
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(detachedFront == nil && store.selectedConversationID == nil)

      Button(pinTitle) {
        guard let id = detachedFront else { return }
        store.togglePinnedDetached(id)
      }
      .keyboardShortcut("p", modifiers: [.command, .option])
      .disabled(detachedFront == nil)
    }

    // Rien ici pour les Réglages : la scène `Settings` pose elle-même son
    // « Settings… » (⌘,) qui ouvre la VRAIE fenêtre. Un `CommandGroup` de plus
    // ne la remplacerait pas, il doublerait l'entrée du menu.
  }
}

/// Un cran du rail dans le menu. Au-delà de ⌘9 on n'attribue plus de raccourci.
private struct NetworkFilterCommand: View {
  let store: InboxStore
  let network: MessageNetwork?
  let position: Int

  var body: some View {
    Button(network?.labelFR ?? "Tous les réseaux") {
      store.setNetworkFilter(network)
    }
    .keyboardShortcut(shortcut)
  }

  private var shortcut: KeyboardShortcut? {
    guard (1...9).contains(position), let digit = "\(position)".first else { return nil }
    return KeyboardShortcut(KeyEquivalent(digit), modifiers: [.command])
  }
}
