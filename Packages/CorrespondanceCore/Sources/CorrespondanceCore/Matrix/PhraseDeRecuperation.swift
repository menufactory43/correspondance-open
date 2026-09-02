import Foundation

/// La phrase de récupération : le seul secret qui survit à la perte de tous
/// les appareils.
///
/// **Pourquoi des mots, et pas une chaîne de base58.** La phrase se recopie à
/// la main sur du papier, une seule fois, par quelqu'un qui ne la relira
/// peut-être jamais. Une suite de mots courts, sans accent ambigu ni
/// homophone, se transcrit sans faute ; `Es1kQ…` ne se transcrit pas.
///
/// **L'entropie ne vient pas de la longueur du texte** mais du tirage : 256
/// mots font 8 bits par mot, donc **96 bits** pour douze mots. La phrase passe
/// ensuite par le PBKDF2 de `BackupRecoveryKey` (500 000 tours) : ces 96 bits
/// sont le plancher, pas le plafond.
public enum PhraseDeRecuperation {

  /// Douze mots : 96 bits, une ligne et demie sur du papier.
  public static let nombreDeMots = 12

  /// Tire une phrase neuve. `SystemRandomNumberGenerator` seulement — jamais
  /// un `Int.random` semé, jamais l'horloge.
  public static func engendrer(nombreDeMots: Int = nombreDeMots) -> String {
    var rng = SystemRandomNumberGenerator()
    return engendrer(nombreDeMots: nombreDeMots, avec: &rng)
  }

  /// La même, avec un générateur qu'un test peut fixer. C'est la seule raison
  /// d'être de cette surcharge : sans elle, aucun test ne peut vérifier la
  /// forme de la phrase.
  public static func engendrer<G: RandomNumberGenerator>(
    nombreDeMots: Int = nombreDeMots, avec rng: inout G
  ) -> String {
    (0..<max(1, nombreDeMots))
      .map { _ in lexique[Int.random(in: 0..<lexique.count, using: &rng)] }
      .joined(separator: " ")
  }

  /// Ce que l'utilisateur retape peut porter des espaces en trop, des
  /// majuscules du correcteur, ou des retours à la ligne collés depuis une
  /// note. La clé, elle, est dérivée d'une chaîne **exacte** : sans cette
  /// normalisation, une phrase juste serait refusée pour une capitale.
  public static func normaliser(_ saisie: String) -> String {
    saisie
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .joined(separator: " ")
  }

  /// Une saisie qui n'a pas la forme d'une phrase n'a pas besoin d'un aller-
  /// retour au Relais pour être refusée. On ne vérifie pas que les mots sont
  /// du lexique : une phrase d'un autre client Matrix doit rester acceptée.
  public static func semblePlausible(_ saisie: String) -> Bool {
    normaliser(saisie).split(separator: " ").count >= 6
  }

  /// 256 mots — 8 bits chacun. Courts, courants, sans accent qui change le
  /// sens, sans paire homophone (« ver / vert / verre » n'y sont pas ensemble).
  /// Le nombre est vérifié par un test : un mot en trop ou en moins déplacerait
  /// silencieusement l'entropie.
  public static let lexique: [String] = [
    "abri", "acier", "aigle", "album", "amande", "ancre", "arbre", "argile",
    "avion", "balcon", "banc", "barque", "bassin", "bijou", "biscuit", "blason",
    "bocal", "bois", "bougie", "boussole", "branche", "brique", "brume", "bruit",
    "buisson", "bureau", "cabane", "cadre", "cahier", "caillou", "canal", "canard",
    "carte", "casque", "cendre", "cercle", "chaise", "champ", "chapeau", "charbon",
    "chateau", "chemin", "chene", "cible", "ciment", "cirque", "citron", "clairon",
    "clef", "cloche", "clou", "cobalt", "colline", "colombe", "comete", "confiture",
    "corail", "corde", "cortex", "coton", "coude", "coupole", "courant", "cratere",
    "crayon", "creme", "crible", "cristal", "cuivre", "cygne", "dalle", "danse",
    "datte", "degel", "delta", "dessin", "digue", "dindon", "diplome", "domaine",
    "donjon", "douve", "drapeau", "dune", "ecaille", "echelle", "eclair", "ecluse",
    "ecole", "ecran", "ecume", "edifice", "eglise", "elan", "email", "encre",
    "enclume", "epaule", "epice", "epine", "eponge", "erable", "escale", "essaim",
    "etable", "etage", "etain", "etang", "etoile", "falaise", "fanal", "fauteuil",
    "fenetre", "ferme", "festin", "feuille", "figue", "filet", "flacon", "flamme",
    "fleuve", "flotte", "fontaine", "forge", "fossile", "foudre", "fougere", "four",
    "fresque", "friche", "fumee", "galet", "galerie", "gant", "garage", "gazon",
    "gel", "genet", "givre", "glacier", "gland", "globe", "gorge", "goutte",
    "grange", "granit", "gravier", "grelot", "grenier", "grive", "grotte", "guitare",
    "hameau", "harpe", "hibou", "horizon", "houle", "huitre", "ile", "index",
    "iris", "ivoire", "jade", "jardin", "jetee", "jonc", "jungle", "kiosque",
    "lagune", "laine", "lampe", "lande", "lanterne", "lavande", "lezard", "libellule",
    "lierre", "limon", "linge", "loutre", "lucarne", "lueur", "lutin", "lynx",
    "magnolia", "maison", "malle", "manteau", "marbre", "maree", "marmite", "matin",
    "meduse", "melodie", "menthe", "meule", "miel", "moineau", "molaire", "montagne",
    "moulin", "mousse", "muraille", "myrtille", "nacre", "nappe", "navire", "nectar",
    "neige", "nid", "noisette", "nuage", "oasis", "ocre", "oiseau", "olive",
    "ombre", "orage", "orange", "orgue", "orme", "ortie", "oursin", "palais",
    "palme", "panier", "parasol", "parfum", "pavot", "peluche", "pendule", "phare",
    "piano", "pierre", "pigeon", "pilier", "pin", "pivoine", "planche", "plateau",
    "pluie", "plume", "poirier", "pollen", "pommier", "pont", "portail", "poterie",
    "poulie", "prairie", "prisme", "puits", "quai", "quartz", "radeau", "rafale",
  ]
}
