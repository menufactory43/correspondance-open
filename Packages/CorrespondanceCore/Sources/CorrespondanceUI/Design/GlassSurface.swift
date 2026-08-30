import SwiftUI
import CorrespondanceCore

/// Verre système (Liquid Glass) quand macOS 26 le fournit, repli opaque sinon.
/// Aucun faux verre fait main : sous `Reduce Transparency` ou `Increase Contrast`
/// on peint une surface pleine et un liseré net, comme le fait le système.
public struct GlassSurface: ViewModifier {
  public var cornerRadius: CGFloat
  public var tint: Color?
  public var fallbackFill: Color
  public var border: Color
  public var isInteractive: Bool = false

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }

  private var prefersOpaque: Bool {
    reduceTransparency || contrast == .increased
  }

  @ViewBuilder
  public func body(content: Content) -> some View {
    if #available(macOS 26.0, *), !prefersOpaque {
      content
        .glassEffect(glass, in: shape)
    } else {
      content
        .background(prefersOpaque ? fallbackFill : fallbackFill.opacity(0.92), in: shape)
        .overlay(
          shape.strokeBorder(
            border.opacity(contrast == .increased ? 1 : 0.6),
            lineWidth: contrast == .increased ? 1.5 : 1
          )
        )
    }
  }

  @available(macOS 26.0, *)
  private var glass: Glass {
    var value = Glass.regular
    if let tint { value = value.tint(tint) }
    if isInteractive { value = value.interactive() }
    return value
  }

  public init(cornerRadius: CGFloat, tint: Color? = nil, fallbackFill: Color, border: Color, isInteractive: Bool = false) {
    self.cornerRadius = cornerRadius
    self.tint = tint
    self.fallbackFill = fallbackFill
    self.border = border
    self.isInteractive = isInteractive
  }
}

public extension View {
  /// Pilule / carte en verre système, avec repli accessible.
  public func glassSurface(
    cornerRadius: CGFloat,
    tint: Color? = nil,
    fallbackFill: Color,
    border: Color,
    isInteractive: Bool = false
  ) -> some View {
    modifier(GlassSurface(
      cornerRadius: cornerRadius,
      tint: tint,
      fallbackFill: fallbackFill,
      border: border,
      isInteractive: isInteractive
    ))
  }

  /// Fond de fenêtre natif (macOS 15+) — remplace le bricolage `NSWindow.backgroundColor`.
  @ViewBuilder
  public func correspondanceWindowBackground(_ color: Color) -> some View {
    if #available(macOS 15.0, *) {
      containerBackground(color, for: .window)
    } else {
      background(color.ignoresSafeArea())
    }
  }
}
