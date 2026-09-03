import Foundation

/// Le flow de connexion Slack, en français.
///
/// Le pont parle anglais : ses instructions (« Enter the email address… »), et
/// jusqu'au bandeau du reCAPTCHA que son script pose sur la page. Les étapes,
/// elles, ont des identifiants stables (`fi.mau.slack.login.enter_email`…) et
/// les phrases d'erreur sont en nombre fini (`login-email.go`). On traduit donc
/// par l'identifiant d'abord, par la phrase ensuite, et on rend l'anglais tel
/// quel si on ne le connaît pas — plutôt qu'un français qui dirait autre chose.
public enum SlackLoginFrench {
  /// L'instruction de l'étape, en français.
  public static func instructions(for step: BridgeLoginProcessStep) -> String {
    let english = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    if let known = phrases[english] { return known }
    // Le succès porte le nom de l'espace et l'adresse : on les garde.
    if english.hasPrefix("Successfully logged into "), let asRange = english.range(of: " as ", options: .backwards) {
      let team = english[english.index(english.startIndex, offsetBy: "Successfully logged into ".count)..<asRange.lowerBound]
      let who = english[asRange.upperBound...]
      return "Connecté à \(team) en tant que \(who)."
    }
    if let byStep = byStepID[step.stepID], !english.isEmpty {
      // Une phrase inconnue sur une étape connue : le français de l'étape, et
      // la phrase du pont en dessous, pour ne rien cacher.
      return byStep + "\n" + english
    }
    return byStepID[step.stepID] ?? english
  }

  /// Le script d'extraction du pont, en français : le bandeau qu'il pose sur la
  /// page, et la langue du reCAPTCHA (`hl=fr`). Un remplacement de chaînes, rien
  /// de plus ; un script sans ces chaînes ressort intact.
  public static func localizedExtractJS(_ script: String) -> String {
    script
      .replacingOccurrences(of: "'Complete the Slack verification'", with: "'Passe la vérification de Slack'")
      .replacingOccurrences(of: "recaptcha/api.js?render=explicit", with: "recaptcha/api.js?hl=fr&render=explicit")
  }

  static let byStepID: [String: String] = [
    "fi.mau.slack.login.enter_email": "Ton adresse e-mail Slack.",
    "fi.mau.slack.login.email_captcha": "Slack demande une vérification avant d'envoyer le code : passe-la ci-dessous.",
    "fi.mau.slack.login.enter_email_code": "Slack t'a envoyé un code par e-mail. Saisis ses six caractères.",
    "fi.mau.slack.login.select_workspace": "Choisis l'espace de travail à connecter.",
    "fi.mau.slack.login.two_factor": "Le code d'authentification demandé par cet espace de travail.",
    "fi.mau.slack.login.enter_auth_token": "Colle la session : l'objet JSON, ou une commande cURL copiée des outils de développement.",
  ]

  static let phrases: [String: String] = [
    "Enter the email address associated with your Slack account.": "Ton adresse e-mail Slack.",
    "Enter a valid Slack account email address.": "Cette adresse n'a pas l'air valide. Vérifie-la.",
    "Slack requires a CAPTCHA before it can email the confirmation code. Complete the embedded challenge to continue.":
      "Slack demande une vérification avant d'envoyer le code : passe-la ci-dessous.",
    "Complete the embedded CAPTCHA before continuing.": "Passe d'abord la vérification ci-dessous.",
    "The CAPTCHA did not return a solution. Complete a new embedded challenge to continue.":
      "La vérification n'a rien rendu. Recommence-la.",
    "Slack rejected or expired that CAPTCHA solution. Complete a new embedded challenge to continue.":
      "Slack a refusé cette vérification, ou elle a expiré. Recommence-la.",
    "Slack is rate limiting email sign-in. Wait a few minutes, then complete a new embedded challenge.":
      "Slack limite les connexions par e-mail. Attends quelques minutes, puis recommence la vérification.",
    "Slack is rate limiting email sign-in. Wait a few minutes before trying again.":
      "Slack limite les connexions par e-mail. Attends quelques minutes avant de réessayer.",
    "Slack rejected that email address. Check it and try again.": "Slack refuse cette adresse. Vérifie-la et réessaie.",
    "Slack requires a CAPTCHA for this sign-in. Complete the embedded challenge and try again.":
      "Slack demande une vérification pour cette connexion. Passe-la et réessaie.",
    "Slack could not start email sign-in. Try again later.": "Slack n'a pas pu démarrer la connexion par e-mail. Réessaie plus tard.",
    "Slack emailed you a confirmation code. Enter the six characters from that email.":
      "Slack t'a envoyé un code par e-mail. Saisis ses six caractères.",
    "Enter the six-character code Slack emailed you.": "Le code fait six caractères : vérifie-le.",
    "Slack rejected that confirmation code. Check the email and try again.": "Slack refuse ce code. Vérifie l'e-mail et réessaie.",
    "That Slack confirmation code expired. Enter your email to request a new one.":
      "Ce code a expiré. Saisis ton adresse pour en recevoir un nouveau.",
    "Slack is rate limiting code checks. Wait before trying again.": "Slack limite les essais de code. Attends un peu avant de réessayer.",
    "Slack did not return any workspaces that support email sign-in for this account.":
      "Aucun espace de travail de ce compte n'accepte la connexion par e-mail.",
    "Choose the Slack workspace to connect.": "Choisis l'espace de travail à connecter.",
    "Choose one of the Slack workspaces in the list.": "Choisis un espace de travail dans la liste.",
    "Enter the authentication code required by this Slack workspace.": "Le code d'authentification demandé par cet espace de travail.",
    "Enter the six-digit code from your authenticator app or SMS.": "Le code à six chiffres de ton application d'authentification, ou reçu par SMS.",
    "Slack is rate limiting authentication-code checks. Wait before trying again.":
      "Slack limite les essais de code d'authentification. Attends un peu avant de réessayer.",
    "That two-factor session expired. Enter a new authentication code.": "La session d'authentification a expiré. Saisis un nouveau code.",
    "Slack rejected that authentication code. Check the code and try again.": "Slack refuse ce code d'authentification. Vérifie-le et réessaie.",
    "Slack did not complete two-factor authentication. Check the code and try again.":
      "Slack n'a pas terminé l'authentification à deux facteurs. Vérifie le code et réessaie.",
    "Slack created a session, but the bridge could not validate it. Enter your email to try again.":
      "Slack a ouvert une session, mais le pont n'a pas pu la valider. Saisis ton adresse pour réessayer.",
  ]
}
