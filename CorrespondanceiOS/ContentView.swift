import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// L'écran qui prouve la frontière : rien d'autre à faire ici que d'instancier
/// un type de Core et une vue de UI. Tant qu'il compile pour l'iPhone, ce que
/// le paquet contient est bien portable.
struct ContentView: View {
  private let conversation = Conversation(
    id: "demo",
    network: .signal,
    address: "+33600000000",
    title: "Core OK",
    preview: "Le paquet compile pour l'iPhone.",
    lastMessageAt: .now,
    unreadCount: 0,
    isArchived: false,
    transportKey: "demo",
    isGroup: false
  )

  var body: some View {
    VStack(spacing: Spacing.md) {
      Text("Core OK")
        .font(.largeTitle)
      Text(conversation.title)
      Text(conversation.network.labelFR)
    }
    .padding()
  }
}
