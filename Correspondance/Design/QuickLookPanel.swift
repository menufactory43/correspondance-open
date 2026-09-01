import AppKit
import Quartz

/// QUICK LOOK, celui du système. Une photo du fil s'ouvre en grand comme dans
/// le Finder — flèches ←→ pour passer aux autres médias du message, Espace pour
/// refermer — et un PDF ou une archive s'y montrent aussi, ce que nous ne
/// saurions pas faire.
@MainActor
enum QuickLookPanel {
  /// La source doit vivre aussi longtemps que le panneau : celui-ci ne la
  /// retient pas.
  private static let source = Source()

  static func open(urls: [URL], startAt index: Int = 0) {
    guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
    source.urls = urls as [NSURL]
    panel.dataSource = source
    panel.makeKeyAndOrderFront(nil)
    panel.reloadData()
    panel.currentPreviewItemIndex = max(0, min(index, urls.count - 1))
  }

  private final class Source: NSObject, QLPreviewPanelDataSource {
    var urls: [NSURL] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
      urls.indices.contains(index) ? urls[index] : nil
    }
  }
}
