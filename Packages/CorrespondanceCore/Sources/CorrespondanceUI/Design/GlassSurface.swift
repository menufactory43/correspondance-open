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
  @Environment(\.glassSurfacePrefersOpaque) private var prefersOpaqueByContext

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }

  private var prefersOpaque: Bool {
    reduceTransparency || contrast == .increased || prefersOpaqueByContext
  }

  // Le contenu reste le MÊME quel que soit le fond : deux branches (`if` verre
  // / surface pleine) recréaient la vue à chaque bascule, et un champ de texte
  // y perdait son focus — le clavier montait puis repartait aussitôt.
  public func body(content: Content) -> some View {
    content.background { backdrop }
  }

  @ViewBuilder
  private var backdrop: some View {
    if #available(macOS 26.0, iOS 26.0, *), !prefersOpaque {
      Color.clear.glassEffect(glass, in: shape)
    } else {
      shape
        .fill(prefersOpaque ? fallbackFill : fallbackFill.opacity(0.92))
        .overlay(
          shape.strokeBorder(
            border.opacity(contrast == .increased ? 1 : 0.6),
            lineWidth: contrast == .increased ? 1.5 : 1
          )
        )
    }
  }

  @available(macOS 26.0, iOS 26.0, *)
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
}

/// Demande aux surfaces de verre de se rendre opaques, le temps d'un
/// mouvement que le verre système ne sait pas suivre : la couche de
/// `glassEffect` ne suit pas un `offset` animé, elle le rattrape après coup.
public struct GlassSurfacePrefersOpaqueKey: EnvironmentKey {
  public static let defaultValue = false
}

public extension EnvironmentValues {
  var glassSurfacePrefersOpaque: Bool {
    get { self[GlassSurfacePrefersOpaqueKey.self] }
    set { self[GlassSurfacePrefersOpaqueKey.self] = newValue }
  }
}
