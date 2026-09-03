// Gare la souris dans le coin bas-droit de l'écran avant une capture : sans
// ça, la barre de survol d'une bulle s'invite sur l'image.
import CoreGraphics
let bounds = CGDisplayBounds(CGMainDisplayID())
CGWarpMouseCursorPosition(CGPoint(x: bounds.maxX - 2, y: bounds.maxY - 2))
