import Foundation

/// Le flow de connexion Telegram, en français.
///
/// Le pont parle anglais, et Telegram aussi quand il refuse : ses erreurs sont
/// des codes (`PHONE_NUMBER_INVALID`, `FLOOD_WAIT_23`…) que le connecteur
/// renvoie tels quels dans la réponse HTTP. Les étapes, elles, ont des
/// identifiants stables (`fi.mau.telegram.login.phone_number`, `….code`,
/// `….password`, et leurs variantes `.incorrect`). On traduit par l'identifiant
/// d'abord, par la phrase ensuite, par le code d'erreur enfin — et on rend
/// l'anglais tel quel si on ne le connaît pas, plutôt qu'un français qui dirait
/// autre chose.
public enum TelegramLoginFrench {
  /// L'instruction de l'étape, en français.
  public static func instructions(for step: BridgeLoginProcessStep) -> String {
    let english = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    if let known = phrases[english] { return known }
    // Le succès porte le nom du compte et son identifiant : on garde le nom.
    if english.hasPrefix("Successfully logged in as ") {
      var who = english.dropFirst("Successfully logged in as ".count)
      if let paren = who.range(of: " (`", options: .backwards) { who = who[..<paren.lowerBound] }
      return "Connecté en tant que \(who)."
    }
    if let byStep = byStepID[step.stepID] {
      // Une phrase inconnue sur une étape connue : le français de l'étape, et
      // la phrase du pont en dessous, pour ne rien cacher.
      return english.isEmpty ? byStep : byStep + "\n" + english
    }
    return english
  }

  /// Une erreur du pont, en français. Telegram répond par des codes en
  /// majuscules ; le connecteur les enveloppe (« failed to send code:
  /// rpc error code 400: PHONE_NUMBER_INVALID »). On cherche le code, pas la
  /// phrase. `nil` si on ne le connaît pas.
  public static func error(_ message: String) -> String? {
    let upper = message.uppercased()
    for (code, french) in errorCodes where upper.contains(code) {
      return french
    }
    // `FLOOD_WAIT_<secondes>` : Telegram dit combien de temps attendre.
    if let range = upper.range(of: #"FLOOD_WAIT_(\d+)"#, options: .regularExpression) {
      let seconds = Int(upper[range].dropFirst("FLOOD_WAIT_".count)) ?? 0
      if seconds >= 3600 {
        return "Telegram limite les essais : réessaie dans \(seconds / 3600) h."
      }
      if seconds >= 60 {
        return "Telegram limite les essais : réessaie dans \(seconds / 60) min."
      }
      return "Telegram limite les essais : réessaie dans \(seconds) s."
    }
    return nil
  }

  static let byStepID: [String: String] = [
    "fi.mau.telegram.login.phone_number": "Ton numéro Telegram, avec l'indicatif du pays (+33 6…).",
    "fi.mau.telegram.login.code": "Telegram t'a envoyé un code dans l'app, sur ton téléphone. Saisis-le.",
    "fi.mau.telegram.login.code.incorrect": "Code refusé. Vérifie-le dans l'app Telegram et réessaie.",
    "fi.mau.telegram.login.password": "Ce compte a la validation en deux étapes : son mot de passe.",
    "fi.mau.telegram.login.password.incorrect":
      "Mot de passe refusé. Réessaie — si tu l'as oublié, l'app Telegram officielle sait le réinitialiser.",
  ]

  static let phrases: [String: String] = [
    "The code was sent to the Telegram app on your phone":
      "Telegram t'a envoyé un code dans l'app, sur ton téléphone. Saisis-le.",
    "Incorrect code": "Code refusé. Vérifie-le dans l'app Telegram et réessaie.",
    "You have two-factor authentication enabled.": "Ce compte a la validation en deux étapes : son mot de passe.",
    "Incorrect password, please try again. Use the official Telegram app to reset your password if you've forgotten it.":
      "Mot de passe refusé. Réessaie — si tu l'as oublié, l'app Telegram officielle sait le réinitialiser.",
  ]

  /// Les codes d'erreur de Telegram qu'on peut croiser en se connectant
  /// (`core.telegram.org/method/auth.sendCode`, `auth.signIn`,
  /// `auth.checkPassword`), et ce qu'ils veulent dire ici.
  static let errorCodes: [(String, String)] = [
    ("PHONE_NUMBER_INVALID", "Ce numéro n'a pas l'air valide. Au format international, avec l'indicatif : +33 6…"),
    ("PHONE_NUMBER_UNOCCUPIED", "Aucun compte Telegram sur ce numéro. Crée-le d'abord dans l'app officielle."),
    ("PHONE_NUMBER_BANNED", "Telegram a banni ce numéro."),
    ("PHONE_NUMBER_FLOOD", "Trop de demandes de code sur ce numéro. Attends un peu avant de réessayer."),
    ("PHONE_PASSWORD_FLOOD", "Trop d'essais de mot de passe. Attends un peu avant de réessayer."),
    ("PHONE_CODE_EXPIRED", "Ce code a expiré. Relance la connexion pour en recevoir un nouveau."),
    ("PHONE_CODE_INVALID", "Code refusé. Vérifie-le dans l'app Telegram et réessaie."),
    ("PHONE_CODE_EMPTY", "Le code est vide."),
    ("PASSWORD_HASH_INVALID", "Mot de passe refusé. Réessaie."),
    ("SESSION_PASSWORD_NEEDED", "Ce compte a la validation en deux étapes : son mot de passe."),
    ("AUTH_RESTART", "Telegram demande de recommencer la connexion depuis le début."),
    ("API_ID_INVALID", "Le Relais n'a pas d'api_id / api_hash Telegram valides dans la config du pont."),
    ("SIGN UP", "Aucun compte Telegram sur ce numéro. Crée-le d'abord dans l'app officielle."),
  ]
}

/// L'aiguillage : le français de chaque pont qui parle par l'API de provisioning.
///
/// Un pont inconnu rend l'anglais tel quel — plutôt qu'un français qui dirait
/// autre chose. C'est là que la fenêtre de connexion vient chercher ses mots,
/// sans savoir lequel des deux ponts est derrière.
public enum BridgeLoginFrench {
  public static func instructions(for step: BridgeLoginProcessStep, network: MessageNetwork) -> String {
    switch network {
    case .slack: SlackLoginFrench.instructions(for: step)
    case .telegram: TelegramLoginFrench.instructions(for: step)
    default: step.instructions
    }
  }

  /// Le message d'une erreur HTTP du pont, en français quand on le connaît —
  /// sinon l'anglais, préfixé du réseau pour qu'on sache qui parle.
  public static func error(_ message: String, network: MessageNetwork) -> String {
    switch network {
    case .telegram: TelegramLoginFrench.error(message) ?? "\(network.labelFR) : \(message)"
    default: "\(network.labelFR) : \(message)"
    }
  }
}
