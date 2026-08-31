import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Correspondance" && (w[kCGWindowLayer as String] as? Int) == 0 {
  if let b = w[kCGWindowBounds as String] as? [String: Any], let h = b["Height"] as? Double, h > 200, let n = w[kCGWindowNumber as String] as? Int { print(n); break }
}
