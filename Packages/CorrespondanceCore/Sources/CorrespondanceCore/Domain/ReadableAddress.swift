import Foundation

extension MessageNetwork {
  /// Ce réseau désigne-t-il les gens par un numéro ? iMessage et Signal, oui ;
  /// WhatsApp par son pont ; Instagram et Messenger, jamais — leur identifiant
  /// numérique est un compte Meta, pas un téléphone.
  public var identifiesByPhone: Bool { bridge?.identifiersArePhoneNumbers ?? true }
}

extension Conversation {
  /// L'adresse qu'on peut montrer à quelqu'un : un numéro en E.164 ou un
  /// e-mail. `nil` quand l'adresse n'est qu'un identifiant technique — un
  /// salon `!abc:correspondance.local`, un compte Meta, un UUID Signal — qui
  /// ne dit rien à personne et n'a pas sa place dans une fiche ni dans un menu.
  public var readableAddress: String? {
    guard network.identifiesByPhone else { return nil }
    if let e164 = PhoneNormalizer.e164(address) { return e164 }
    if address.contains("@"), !address.hasPrefix("@"), address.contains(".") { return address }
    if let key = PhoneNormalizer.identityKey(for: address) {
      if key.hasPrefix("tel:") { return "+" + key.dropFirst(4) }
      if key.hasPrefix("email:") { return String(key.dropFirst(6)) }
    }
    return nil
  }

  /// « Signal · +33 6… », ou « Signal » tout seul quand il n'y a rien de lisible à ajouter.
  public var networkAndReadableAddress: String {
    if let readable = readableAddress { return "\(network.labelFR) · \(readable)" }
    return network.labelFR
  }
}
