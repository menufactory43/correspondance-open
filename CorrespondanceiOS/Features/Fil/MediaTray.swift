import AVFoundation
import CorrespondanceCore
import CorrespondanceUI
import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Ce que le « + » ouvre : la pellicule, à la place du clavier.
///
/// Les derniers médias de la photothèque en bande, une tape joint, une autre
/// retire. En bas, les portes qui restent : toute la photothèque, la caméra,
/// un fichier, « Plus tard ». Le plateau est un vrai `inputView` UIKit
/// (`MediaTrayInputHost`) : c'est le système qui l'échange avec le clavier,
/// dans le même mouvement — comme Signal.
struct MediaTray: View {
  let conversationID: String
  /// La pellicule, tenue par le composer : elle survit aux ouvertures et
  /// fermetures du plateau, avec ses vignettes déjà rendues.
  let library: RecentLibrary
  /// Les portes du bas. Leurs feuilles se présentent depuis le composer :
  /// depuis un `inputView`, rien ne se présente.
  let onPhotos: () -> Void
  let onCamera: () -> Void
  let onFile: () -> Void
  let onSendLater: () -> Void

  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  /// Le chemin joint pour chaque média choisi ici : c'est lui qu'on retire.
  @State private var chosen: [String: String] = [:]
  @State private var exporting: Set<String> = []

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  /// Une vignette : carrée, grande, arrondie — la pellicule se feuillette
  /// de côté, elle ne se quadrille pas.
  private static let tileSide: CGFloat = 150
  private static let tileRadius: CGFloat = 22

  var body: some View {
    VStack(spacing: 0) {
      strip
        .frame(maxHeight: .infinity)
      doors
        .padding(.bottom, Spacing.md)
        .safeAreaPadding(.bottom)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.paperSecondary, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    .padding(.horizontal, 4)
    .background(theme.paper)
    .task { await library.load() }
    .onChange(of: store.attachments(conversationID)) { _, paths in
      // Retirée depuis la bande du composer : la tuile se déselectionne.
      chosen = chosen.filter { paths.contains($0.value) }
    }
  }

  // MARK: - La pellicule

  @ViewBuilder
  private var strip: some View {
    switch library.state {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .denied:
      VStack(spacing: Spacing.xs) {
        Image(systemName: "photo.on.rectangle.angled")
          .font(.system(size: 28))
          .foregroundStyle(theme.inkTertiary)
        Text("Correspondance n'a pas accès à la photothèque.")
          .font(Typography.meta(typeface))
          .foregroundStyle(theme.inkSecondary)
          .multilineTextAlignment(.center)
        Button("Ouvrir les Réglages") {
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        .font(Typography.meta(typeface))
        .tint(theme.accent)
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .ready:
      ScrollView(.horizontal) {
        LazyHStack(spacing: Spacing.xs) {
          ForEach(library.assets, id: \.localIdentifier) { asset in
            tile(asset, side: Self.tileSide)
          }
        }
        .padding(.horizontal, Spacing.md)
      }
      .scrollIndicators(.hidden)
      .scrollClipDisabled()
    }
  }

  private func tile(_ asset: PHAsset, side: CGFloat) -> some View {
    let isChosen = chosen[asset.localIdentifier] != nil
    let shape = RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous)
    return Button {
      toggle(asset)
    } label: {
      ZStack(alignment: .topTrailing) {
        AssetThumbnail(asset: asset, side: side, library: library, placeholder: theme.bubbleIn)
          .frame(width: side, height: side)
          .clipShape(shape)
          // En surcouche, pas dans la pile : un cadre extensible y faisait
          // grandir la tuile vidéo, décalée d'autant à côté des photos.
          .overlay(alignment: .bottomTrailing) {
            if asset.mediaType == .video {
              Text(Self.duration(asset.duration))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(8)
            }
          }
        if exporting.contains(asset.localIdentifier) {
          ProgressView()
            .tint(.white)
            .padding(6)
            .background(.black.opacity(0.45), in: Circle())
            .padding(8)
        } else if isChosen {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 24))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, theme.accent)
            .padding(8)
        }
      }
      .overlay {
        if isChosen { shape.strokeBorder(theme.accent, lineWidth: 3) }
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(asset.mediaType == .video ? "Vidéo" : "Photo")
    .accessibilityAddTraits(isChosen ? [.isSelected] : [])
  }

  private func toggle(_ asset: PHAsset) {
    let key = asset.localIdentifier
    if let path = chosen[key] {
      chosen.removeValue(forKey: key)
      store.removeAttachment(path, conversationID: conversationID)
      return
    }
    guard !exporting.contains(key) else { return }
    exporting.insert(key)
    Task {
      let path = await library.export(asset)
      exporting.remove(key)
      guard let path else { return }
      chosen[key] = path
      store.addAttachment(path, conversationID: conversationID)
    }
  }

  private static func duration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  // MARK: - Les portes

  private var doors: some View {
    ScrollView(.horizontal) {
      HStack(alignment: .top, spacing: Spacing.xs) {
        // Ligne fusionnée : la porte du réseau d'envoi, en tête — c'est la seule
        // qui change d'un fil à l'autre. Elle dit où part le prochain message
        // et en change ; le choix reste, ici et sur le Mac.
        if let active = store.activeMember(of: conversationID) {
          Menu {
            Section("Changer de chat") {
              ForEach(store.memberConversations(of: conversationID)) { member in
                Button {
                  store.setActiveMember(mergedID: conversationID, conversationID: member.id)
                } label: {
                  Label {
                    Text(member.networkAndReadableAddress)
                  } icon: {
                    Image(systemName: member.id == active.id ? "checkmark" : member.network.systemImage)
                  }
                }
              }
            }
          } label: {
            Door(title: active.network.labelFR, systemImage: active.network.systemImage, theme: theme)
          }
          .accessibilityLabel("Chat actif : \(active.network.labelFR). Changer de réseau d'envoi.")
        }
        Button(action: onPhotos) { Door(title: "Photos", systemImage: "photo.on.rectangle", theme: theme) }
        Button(action: onCamera) { Door(title: "Caméra", systemImage: "camera", theme: theme) }
        Button(action: onFile) { Door(title: "Fichier", systemImage: "doc", theme: theme) }
        Button(action: onSendLater) { Door(title: "Plus tard", systemImage: "clock", theme: theme) }
      }
      .padding(.horizontal, Spacing.md)
    }
    .scrollIndicators(.hidden)
    .buttonStyle(.plain)
  }
}

/// Une porte du bas : une pastille blanche, le mot dessous — comme Signal.
private struct Door: View {
  let title: String
  let systemImage: String
  let theme: WritingTheme

  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(theme.ink)
        .frame(width: 76, height: 50)
        .background(theme.paper, in: Capsule())
      Text(title)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(theme.ink)
    }
    .opacity(isEnabled ? 1 : 0.4)
    .contentShape(Rectangle())
  }
}

/// Une vignette de la pellicule, demandée au gestionnaire d'images de PhotoKit.
private struct AssetThumbnail: View {
  let asset: PHAsset
  let side: CGFloat
  let library: RecentLibrary
  let placeholder: Color

  @State private var image: UIImage?

  var body: some View {
    ZStack {
      placeholder
      if let image = image ?? library.cachedThumbnail(asset) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      }
    }
    .task(id: asset.localIdentifier) {
      image = await library.thumbnail(asset, side: side)
    }
  }
}

/// La pellicule : ses derniers médias, leurs vignettes, et l'export d'un
/// média vers un fichier que le composer sait joindre.
@MainActor
@Observable
final class RecentLibrary {
  enum State: Equatable { case loading, denied, ready }

  private(set) var state: State = .loading
  private(set) var assets: [PHAsset] = []
  private let manager = PHCachingImageManager()
  /// Les vignettes déjà rendues : rouvrir le plateau ne redemande rien.
  private var thumbnails: [String: UIImage] = [:]

  func load() async {
    guard state == .loading, assets.isEmpty else { return }
    var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if status == .notDetermined {
      status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }
    guard status == .authorized || status == .limited else {
      state = .denied
      return
    }
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    options.fetchLimit = 40
    options.predicate = NSPredicate(
      format: "mediaType == %d || mediaType == %d",
      PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
    )
    let result = PHAsset.fetchAssets(with: options)
    var list: [PHAsset] = []
    list.reserveCapacity(result.count)
    result.enumerateObjects { asset, _, _ in list.append(asset) }
    assets = list
    state = .ready
  }

  func cachedThumbnail(_ asset: PHAsset) -> UIImage? { thumbnails[asset.localIdentifier] }

  func thumbnail(_ asset: PHAsset, side: CGFloat) async -> UIImage? {
    if let hit = thumbnails[asset.localIdentifier] { return hit }
    let scale = UIScreen.main.scale
    let target = CGSize(width: side * scale, height: side * scale)
    let options = PHImageRequestOptions()
    // Une seule livraison : l'opportuniste rappelle deux fois, ce qu'une
    // continuation ne supporte pas.
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true
    let image: UIImage? = await withCheckedContinuation { continuation in
      manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { image, _ in
        continuation.resume(returning: image)
      }
    }
    if let image { thumbnails[asset.localIdentifier] = image }
    return image
  }

  /// Un fichier dans le temporaire : JPEG pour une photo (le HEIC ne passe
  /// pas tous les ponts), MP4 H.264 pour une vidéo (le `.mov` non plus).
  func export(_ asset: PHAsset) async -> String? {
    switch asset.mediaType {
    case .image: return await exportImage(asset)
    case .video: return await exportVideo(asset)
    default: return nil
    }
  }

  private func exportImage(_ asset: PHAsset) async -> String? {
    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    let data: Data? = await withCheckedContinuation { continuation in
      manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
        continuation.resume(returning: data)
      }
    }
    guard let data else { return nil }
    let uti = (asset.value(forKey: "uniformTypeIdentifier") as? String) ?? ""
    let keepsAsIs = uti.contains("jpeg") || uti.contains("png") || uti.contains("gif")
    let payload: Data
    let ext: String
    if keepsAsIs {
      payload = data
      ext = uti.contains("png") ? "png" : (uti.contains("gif") ? "gif" : "jpg")
    } else {
      guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
      payload = jpeg
      ext = "jpg"
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    return (try? payload.write(to: url)) == nil ? nil : url.path
  }

  private func exportVideo(_ asset: PHAsset) async -> String? {
    let options = PHVideoRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    // La session vit et exporte hors de l'acteur principal : l'export est
    // long, et la session n'est pas Sendable.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
    let manager = manager
    let exported: Bool = await withCheckedContinuation { continuation in
      manager.requestExportSession(
        forVideo: asset, options: options, exportPreset: AVAssetExportPresetHighestQuality
      ) { session, _ in
        guard let session else {
          continuation.resume(returning: false)
          return
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.exportAsynchronously {
          continuation.resume(returning: session.status == .completed)
        }
      }
    }
    return exported ? url.path : nil
  }
}
