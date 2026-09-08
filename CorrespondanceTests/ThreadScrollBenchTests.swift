import AppKit
import SwiftUI
import XCTest
@testable import Correspondance
import CorrespondanceCore
import CorrespondanceUI

/// Banc de défilement : le vrai `ThreadView`, hébergé dans une fenêtre, avec un
/// fil de la forme du plus gros groupe connu (243 messages, 26 auteurs, des
/// citations, des réactions, des aperçus, des pièces jointes). On fait défiler
/// par pas et on chronomètre : un fil qui rame se voit ici en millisecondes.
@MainActor
final class ThreadScrollBenchTests: XCTestCase {
  private static let conversationID = "sig:banc-40"

  /// Des fichiers comme les vrais : des photos de 2000 × 1500 et des vignettes
  /// d'aperçu de 1200 × 630, écrites une fois dans un dossier temporaire.
  private static let mediaDirectory: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("banc-40-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  private static func writeImage(named name: String, width: Int, height: Int, seed: Int) -> String {
    let url = mediaDirectory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: url.path) { return url.path }
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0
    )!
    // Du bruit : ça ne se compresse pas, comme une photo.
    var rng = UInt64(truncatingIfNeeded: seed &* 6_364_136_223_846_793_005 &+ 1)
    let data = rep.bitmapData!
    for i in stride(from: 0, to: rep.bytesPerRow * height, by: 4) {
      rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      data[i] = UInt8(truncatingIfNeeded: rng >> 24)
      data[i + 1] = UInt8(truncatingIfNeeded: rng >> 32)
      data[i + 2] = UInt8(truncatingIfNeeded: rng >> 40)
      data[i + 3] = 255
    }
    let type: NSBitmapImageRep.FileType = name.hasSuffix(".png") ? .png : .jpeg
    try? rep.representation(using: type, properties: [.compressionFactor: 0.8])?.write(to: url)
    return url.path
  }

  private func bigGroup() -> [ChatMessage] {
    let senders = (0..<26).map { "Membre \($0 + 1)" }
    let base = Date(timeIntervalSince1970: 1_756_000_000)
    var messages: [ChatMessage] = []
    for i in 0..<243 {
      let sender = senders[i % senders.count]
      let isFromMe = i % 9 == 0
      var text: String
      switch i % 11 {
      case 0: text = "On se retrouve où pour l'anniversaire ? Je propose le parc, vers 15 h"
      case 3: text = "Regardez ça https://example.com/photos/\(i) c'est exactement ce qu'il faut"
      case 5: text = "👍"
      case 7: text = "Ok"
      default: text = "Message numéro \(i) du groupe, avec un peu de texte pour ressembler à la vraie vie."
      }
      if i % 17 == 0 { text += " Et encore une ligne, parce que certains écrivent long, très long, vraiment très long dans ce groupe." }
      var reactions: [MessageReaction] = []
      if i % 5 == 0 { reactions.append(MessageReaction(emoji: "❤️", senders: ["Membre 3", "Membre 7"], isMine: i % 10 == 0)) }
      if i % 13 == 0 { reactions.append(MessageReaction(emoji: "😂", senders: ["Membre 12"])) }
      let reply: QuotedMessage? = i % 8 < 3 && i > 3
        ? QuotedMessage(messageID: "m\(i - 3)", senderName: senders[(i - 3) % senders.count], text: "Message numéro \(i - 3) du groupe")
        : nil
      let preview: BridgedLinkPreview? = i % 11 == 3 && i % 2 == 1
        ? BridgedLinkPreview(
          url: "https://example.com/photos/\(i)", title: "Photos \(i)",
          description: "Un aperçu de lien comme le pont en fabrique.",
          imageMXC: "mxc://relais/og\(i)", imageContentType: "image/png",
          imageLocalPath: Self.writeImage(named: "og\(i).png", width: 1200, height: 630, seed: i)
        )
        : nil
      let attachments: [MessageAttachment] = i % 10 == 4
        ? [MessageAttachment(
          id: "mxc://relais/pj\(i)", contentType: "image/jpeg", filename: "pj\(i).jpg",
          localPath: Self.writeImage(named: "pj\(i).jpg", width: 2000, height: 1500, seed: i)
        )]
        : []
      messages.append(ChatMessage(
        id: "m\(i)",
        conversationID: Self.conversationID,
        network: .signal,
        text: text,
        sentAt: base.addingTimeInterval(Double(i) * 340),
        isFromMe: isFromMe,
        senderID: "@signal_\(i % senders.count):relais",
        senderName: isFromMe ? nil : sender,
        attachments: attachments,
        reactions: reactions,
        replyTo: reply,
        linkPreview: preview
      ))
    }
    return messages
  }

  private func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  /// Le défileur du fil : le plus haut de la fenêtre (le composer en a un aussi).
  private func scrollView(in view: NSView) -> NSScrollView? {
    var all: [NSScrollView] = []
    func walk(_ v: NSView) {
      if let scroll = v as? NSScrollView { all.append(scroll) }
      v.subviews.forEach(walk)
    }
    walk(view)
    return all.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
  }

  /// Le fil monté dans une fenêtre, prêt à être mesuré.
  private func hostedThread() async -> (host: NSHostingView<some View>, window: NSWindow, store: InboxStore) {
    // Hors lancement réel : le fil n'attend pas la première fenêtre de l'app.
    await LaunchGate.firstWindowOnScreen(timeout: .zero)
    let store = InboxStore()
    store.conversations = [Conversation(
      id: Self.conversationID, network: .signal, address: "groupe", title: "Banc 40",
      preview: "…", lastMessageAt: Date(), unreadCount: 0, isArchived: false,
      transportKey: Self.conversationID, isGroup: true
    )]
    store.selectedConversationID = Self.conversationID
    store.messages = bigGroup()
    let themes = ThemePreferences()

    let root = ThreadView().environment(store).environment(themes).frame(width: 640, height: 820)
    let host = NSHostingView(rootView: root)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 820),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = host
    // Derrière les autres fenêtres : le banc ne vole pas le focus.
    window.orderBack(nil)
    // Le fil paraît par sa queue puis s'étend : on lui laisse le temps.
    pump(1.5)
    return (host, window, store)
  }

  /// Le temps CPU du fil principal : ce que SwiftUI a vraiment travaillé
  /// pendant une pompe, sans compter l'attente.
  private func mainThreadCPUMilliseconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6
  }

  /// Un `/sync` touche `conversations` toutes les quelques secondes — un
  /// aperçu, un accusé, « écrit… » — et le corps du fil se refait. Il ne doit
  /// pas remettre en page ses cent cinquante rangées à chaque fois : mesuré
  /// au Time Profiler sur un vrai groupe, 250 ms de layout par `/sync`, le
  /// fil gelé le temps d'une frame sur quinze.
  func testUnRafraichissementDuMagasinNeRemetPasLeFilEnPage() async throws {
    let (_, window, store) = await hostedThread()
    // Le plancher : ce que le fil principal dépense en pompant sans que rien
    // ne change (tâches de fond, images qui finissent d'arriver).
    var floor: [Double] = []
    for _ in 0..<12 {
      let before = mainThreadCPUMilliseconds()
      pump(0.12)
      floor.append(mainThreadCPUMilliseconds() - before)
    }
    let passesBefore = ThreadView.bodyPasses
    var perPass: [Double] = []
    for i in 0..<12 {
      var row = store.conversations[0]
      row.preview = "aperçu \(i)"
      row.lastMessageAt = Date()
      let before = mainThreadCPUMilliseconds()
      store.conversations = [row]
      pump(0.12)
      perPass.append(mainThreadCPUMilliseconds() - before)
    }
    let passes = ThreadView.bodyPasses - passesBefore
    let sorted = perPass.sorted()
    let median = sorted[sorted.count / 2]
    let floorMedian = floor.sorted()[floor.count / 2]
    print("[BANC-SYNC] médiane \(String(format: "%.1f", median)) ms CPU · pire \(String(format: "%.1f", sorted.last ?? 0)) ms · plancher \(String(format: "%.1f", floorMedian)) ms · passes du corps \(passes)/12")
    window.orderOut(nil)
    XCTAssertEqual(passes, 0, "un /sync ordinaire refait le corps du fil")
    XCTAssertLessThan(median - floorMedian, 10, "un /sync remet le fil en page : \(median) ms")
  }

  /// La passe de contraintes d'AppKit demande à l'hôte sa taille minimale et
  /// sa taille idéale à chaque frame d'un défilement. Mesuré au `sample` sur
  /// un vrai groupe : 62 % du fil principal, parce que le fil entier se
  /// remesurait à largeur nulle. Il ne doit plus coûter que le composer.
  func testLaTailleMinimaleDeLHoteNeRemesurePasLeFil() async throws {
    let (host, window, _) = await hostedThread()
    var perPass: [Double] = []
    for _ in 0..<20 {
      let t0 = CFAbsoluteTimeGetCurrent()
      host.invalidateIntrinsicContentSize()
      _ = host.intrinsicContentSize
      _ = host.fittingSize
      perPass.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }
    let sorted = perPass.sorted()
    let median = sorted[sorted.count / 2]
    print("[BANC-TAILLE-MIN] médiane \(String(format: "%.2f", median)) ms · pire \(String(format: "%.2f", sorted.last ?? 0)) ms")
    window.orderOut(nil)
    XCTAssertLessThan(median, 3, "la taille minimale de l'hôte remesure le fil : \(median) ms")
  }

  /// Quand le corps du fil DOIT se refaire (ici : la barre ⌘F qui paraît),
  /// les rangées, elles, n'ont pas bougé : comparables, elles ne doivent ni
  /// se refaire ni se remesurer. C'est le coût d'une fin de geste, d'une
  /// frappe, d'un accusé — tout ce qui touche le fil sans toucher ses bulles.
  func testUnePasseDuCorpsNeRemetPasLesRangeesEnPage() async throws {
    let (_, window, store) = await hostedThread()
    var perPass: [Double] = []
    let rowsBefore = MessageGroupRow.bodyPasses
    let bubblesBefore = MessageBubbleView.bodyPasses
    // `BANC_ROUNDS` : plus de tours quand on veut échantillonner la boucle.
    let rounds = ProcessInfo.processInfo.environment["BANC_ROUNDS"].flatMap(Int.init) ?? 12
    for _ in 0..<rounds {
      let before = mainThreadCPUMilliseconds()
      store.isThreadSearchActive.toggle()
      pump(0.12)
      perPass.append(mainThreadCPUMilliseconds() - before)
    }
    let sorted = perPass.sorted()
    let median = sorted[sorted.count / 2]
    print("[BANC-CORPS] médiane \(String(format: "%.1f", median)) ms CPU · pire \(String(format: "%.1f", sorted.last ?? 0)) ms · rangées refaites \(MessageGroupRow.bodyPasses - rowsBefore) · bulles refaites \(MessageBubbleView.bodyPasses - bubblesBefore) (\(rounds) passes)")
    window.orderOut(nil)
    // Le prix d'une passe quand elle est due : SwiftUI reparcourt le graphe
    // des deux cents rangées même sans rien refaire. ~55 ms en Debug sur ce
    // groupe ; le double, c'est une régression (le `thread` refiltré par
    // rangée en coûtait 20 de plus).
    XCTAssertLessThan(median, 100, "une passe du corps remet les rangées en page : \(median) ms")
  }

  func testLeGrosGroupeDefileSansRamer() async throws {
    // Hors lancement réel : le fil n'attend pas la première fenêtre de l'app.
    await LaunchGate.firstWindowOnScreen(timeout: .zero)
    let store = InboxStore()
    store.conversations = [Conversation(
      id: Self.conversationID, network: .signal, address: "groupe", title: "Banc 40",
      preview: "…", lastMessageAt: Date(), unreadCount: 0, isArchived: false,
      transportKey: Self.conversationID, isGroup: true
    )]
    store.selectedConversationID = Self.conversationID
    store.messages = bigGroup()
    let themes = ThemePreferences()

    let root = ThreadView().environment(store).environment(themes).frame(width: 640, height: 820)
    let host = NSHostingView(rootView: root)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 820),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = host
    // Derrière les autres fenêtres : le banc ne vole pas le focus.
    window.orderBack(nil)
    // Le fil paraît par sa queue puis s'étend : on lui laisse le temps.
    pump(1.5)

    let scroll = try XCTUnwrap(scrollView(in: host), "pas de NSScrollView sous ThreadView")
    let clip = scroll.contentView
    let contentHeight = scroll.documentView?.frame.height ?? 0
    XCTAssertGreaterThan(contentHeight, 5_000, "le fil devrait être long : \(contentHeight)")

    let steps = 40
    let stepHeight: CGFloat = 180
    var startY = clip.bounds.origin.y
    var perStep: [Double] = []
    // Défiler ne refait jamais le corps du fil : le lecteur qui remonte, le
    // geste qui commence ou finit, tout cela vit dans `ThreadScrollTracker`.
    let bodyPassesBefore = ThreadView.bodyPasses
    let began = CFAbsoluteTimeGetCurrent()
    for _ in 0..<steps {
      let t0 = CFAbsoluteTimeGetCurrent()
      startY = max(0, startY - stepHeight)
      clip.scroll(to: NSPoint(x: 0, y: startY))
      scroll.reflectScrolledClipView(clip)
      // Ce que SwiftUI fait à la suite du défilement — c'est ce qu'on mesure.
      pump(0.004)
      perStep.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }
    let total = (CFAbsoluteTimeGetCurrent() - began) * 1000
    let sorted = perStep.sorted()
    let median = sorted[sorted.count / 2]
    let worst = sorted.last ?? 0
    let slowest = perStep.enumerated().sorted { $0.element > $1.element }.prefix(5)
      .map { "#\($0.offset)=\(Int($0.element))" }.joined(separator: " ")
    print("[BANC-DEFILEMENT] pas les plus lents \(slowest)")
    print("[BANC-DEFILEMENT] total \(Int(total)) ms · médiane \(String(format: "%.1f", median)) ms/pas · pire \(String(format: "%.1f", worst)) ms · hauteur \(Int(contentHeight))")
    window.orderOut(nil)

    // Un pas de défilement doit tenir dans une frame (16 ms), avec de la marge
    // pour une machine chargée : 25 ms en médiane, c'est déjà un fil qui rame.
    XCTAssertLessThan(median, 25, "défilement lent : médiane \(median) ms par pas")
    XCTAssertEqual(ThreadView.bodyPasses - bodyPassesBefore, 0, "défiler a refait le corps du fil")
  }
}
