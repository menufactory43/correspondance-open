// Imprime l'identifiant de la plus grande fenêtre de Correspondance, pour
// `screencapture -l`. Lancé par scripts/demo-mac.sh : `swift scripts/window-id.swift`.
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
var best: (id: Int, area: Double) = (0, 0)
for w in list where (w["kCGWindowOwnerName"] as? String) == "Correspondance" && (w["kCGWindowLayer"] as? Int) == 0 {
  let b = w["kCGWindowBounds"] as! [String: Any]
  let area = (b["Width"] as! Double) * (b["Height"] as! Double)
  if area > best.area { best = (w["kCGWindowNumber"] as! Int, area) }
}
print(best.id)
