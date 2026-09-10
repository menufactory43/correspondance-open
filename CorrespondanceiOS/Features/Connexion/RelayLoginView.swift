import CorrespondanceCore
import CorrespondanceUI
import SwiftUI

/// La connexion au Relais.
///
/// Trois champs et rien d'autre : l'adresse du Relais (jamais préremplie d'une
/// IP en dur — seulement de ce que l'utilisateur a saisi la dernière fois),
/// l'identifiant, le mot de passe. Le jeton part au Trousseau
/// (`MatrixCredentialStore`), jamais dans `UserDefaults`.
struct RelayLoginView: View {
  @Environment(RelayStore.self) private var store
  @Environment(ThemePreferences.self) private var themes

  @State private var homeserver = ""
  @State private var user = ""
  @State private var password = ""
  @FocusState private var focus: Field?

  private enum Field { case homeserver, user, password }

  private var theme: WritingTheme { themes.theme }
  private var typeface: WritingTypeface { themes.typeface }

  private var canSubmit: Bool {
    !homeserver.trimmingCharacters(in: .whitespaces).isEmpty
      && !user.trimmingCharacters(in: .whitespaces).isEmpty
      && !password.isEmpty
      && store.session != .connecting
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        header

        VStack(spacing: Spacing.sm) {
          field(
            "Adresse du Relais",
            hint: "relais.local:8008",
            text: $homeserver,
            field: .homeserver
          )
          .textContentType(.URL)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()

          field("Identifiant", hint: "prénom", text: $user, field: .user)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

          secureField
        }

        if let error = store.connectionError {
          errorBanner(error)
        }

        submit

        Text(
          "Le Relais est ton serveur, celui qui porte tes conversations WhatsApp, "
            + "Instagram, Messenger, X, Slack et Signal. Il faut être sur son réseau pour l’atteindre."
        )
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)

        sansRelais
      }
      .padding(Spacing.lg)
      .frame(maxWidth: 520)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(theme.paper.ignoresSafeArea())
    .onAppear {
      if homeserver.isEmpty { homeserver = store.rememberedHomeserver }
    }
  }

  /// Le site, là où l'app Mac se télécharge. L'iPhone ne pose pas de Relais :
  /// il s'y connecte.
  private static let siteMac = URL(string: "https://correspondance-eta.vercel.app/")!

  /// Quelqu'un qui installe l'app iPhone en premier n'a rien à écrire dans
  /// ces trois champs : un Relais se pose depuis le Mac, en un clic, et c'est
  /// lui qui donne l'adresse et le code. Sans ce paragraphe, l'écran était
  /// une impasse — c'est ce qu'a vu le premier testeur.
  private var sansRelais: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Pas encore de Relais ?")
        .font(Typography.body(typeface))
        .foregroundStyle(theme.ink)
      Text(
        "Il se pose depuis Correspondance pour Mac, en un clic : l’app l’installe, "
          + "puis te donne l’adresse et l’identifiant à saisir ici."
      )
      .font(Typography.meta(typeface))
      .foregroundStyle(theme.inkSecondary)
      .fixedSize(horizontal: false, vertical: true)
      Link("Télécharger Correspondance pour Mac", destination: Self.siteMac)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.accent)
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.paperSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Correspondance")
        .font(Typography.letterTitle(typeface, 30))
        .foregroundStyle(theme.ink)
      Text("Se connecter au Relais")
        .font(Typography.body(typeface))
        .foregroundStyle(theme.inkSecondary)
    }
    .padding(.top, Spacing.xl)
    .accessibilityAddTraits(.isHeader)
  }

  private func field(
    _ label: String,
    hint: String,
    text: Binding<String>,
    field: Field
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkSecondary)
      TextField("", text: text, prompt: Text(hint).foregroundStyle(theme.inkTertiary))
        .textFieldStyle(.plain)
        .font(Typography.body(typeface))
        .foregroundStyle(theme.ink)
        .focused($focus, equals: field)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 12)
        .glassSurface(
          cornerRadius: 12,
          fallbackFill: theme.paperSecondary,
          border: focus == field ? theme.accent.opacity(0.5) : theme.edge
        )
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
  }

  private var secureField: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Mot de passe")
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.inkSecondary)
      SecureField("", text: $password, prompt: Text("••••••••").foregroundStyle(theme.inkTertiary))
        .textFieldStyle(.plain)
        .font(Typography.body(typeface))
        .foregroundStyle(theme.ink)
        .textContentType(.password)
        .focused($focus, equals: .password)
        .submitLabel(.go)
        .onSubmit { submitIfPossible() }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 12)
        .glassSurface(
          cornerRadius: 12,
          fallbackFill: theme.paperSecondary,
          border: focus == .password ? theme.accent.opacity(0.5) : theme.edge
        )
    }
    .accessibilityLabel("Mot de passe")
  }

  private func errorBanner(_ message: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.xs) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(theme.accent)
      Text(message)
        .font(Typography.meta(typeface))
        .foregroundStyle(theme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.accentSoft.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Erreur de connexion. \(message)")
  }

  private var submit: some View {
    Button {
      submitIfPossible()
    } label: {
      HStack(spacing: Spacing.xs) {
        if store.session == .connecting {
          ProgressView().tint(theme.accentInk)
        }
        Text(store.session == .connecting ? "Connexion…" : "Se connecter")
          .font(Typography.body(typeface))
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(theme.accentFill.opacity(canSubmit ? 1 : 0.4), in: Capsule())
      .foregroundStyle(theme.accentInk)
    }
    .buttonStyle(.plain)
    .disabled(!canSubmit)
    .accessibilityLabel("Se connecter au Relais")
  }

  private func submitIfPossible() {
    guard canSubmit else { return }
    focus = nil
    Task { await store.connect(homeserver: homeserver, user: user, password: password) }
  }
}
