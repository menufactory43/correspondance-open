import Foundation

/// Le protocole graphique de Kitty — que Ghostty et WezTerm parlent aussi.
///
/// On s'en sert d'une seule manière, la plus robuste pour une TUI qui défile :
/// les **placeholders Unicode**. L'image est transmise une fois et reçoit une
/// placement *virtuel* (`U=1`) de `c`×`r` cellules ; l'endroit où elle se voit
/// est ensuite décidé par des cellules de texte ordinaires — le caractère
/// `U+10EEEE`, deux diacritiques pour la ligne et la colonne, et la couleur
/// d'avant-plan pour l'identifiant de l'image. Conséquences :
///
/// - l'image défile avec le texte, se coupe au bord d'un panneau, disparaît
///   sous une fenêtre surgissante — sans une seule commande de plus ;
/// - le rendu différentiel s'applique aux images comme au texte ;
/// - redessiner ne retransmet rien.
public enum KittyGraphics {
  /// Comment le fichier atteint le terminal.
  public enum Transmission: Sendable {
    /// Le terminal lit le fichier lui-même (`t=f`) : instantané, mais seulement
    /// si le terminal tourne sur la même machine.
    case file
    /// Les octets passent dans le flux (`t=d`, base64 par morceaux) : marche
    /// derrière SSH.
    case direct
  }

  /// La requête de détection : une image d'un pixel, jamais affichée. Le
  /// terminal qui comprend répond `OK` avant la réponse à DA1.
  public static let probeID = 31
  public static let probe = "\u{1B}_Gi=\(probeID),s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\\u{1B}[16t\u{1B}[?u\u{1B}[?2026$p\u{1B}[c"

  /// Transmet un PNG et pose sa placement virtuelle de `columns`×`rows` cellules.
  /// `q=2` : le terminal ne répond pas, ni en succès ni en erreur — rien ne
  /// vient polluer l'entrée.
  public static func transmit(pngAt path: String, id: UInt32, columns: Int, rows: Int, transmission: Transmission) -> [UInt8] {
    var out: [UInt8] = []
    switch transmission {
    case .file:
      let encodedPath = Data(path.utf8).base64EncodedString()
      out += Array("\u{1B}_Ga=T,U=1,q=2,f=100,t=f,i=\(id),c=\(columns),r=\(rows);\(encodedPath)\u{1B}\\".utf8)
    case .direct:
      guard let data = FileManager.default.contents(atPath: path) else { return [] }
      let encoded = Array(data.base64EncodedString().utf8)
      let chunk = 4096
      var offset = 0
      var first = true
      while offset < encoded.count {
        let end = min(offset + chunk, encoded.count)
        let more = end < encoded.count ? 1 : 0
        if first {
          out += Array("\u{1B}_Ga=T,U=1,q=2,f=100,t=d,i=\(id),c=\(columns),r=\(rows),m=\(more);".utf8)
          first = false
        } else {
          out += Array("\u{1B}_Gm=\(more),q=2;".utf8)
        }
        out += encoded[offset..<end]
        out += Array("\u{1B}\\".utf8)
        offset = end
      }
    }
    return out
  }

  /// Oublie une image côté terminal (placements et données).
  public static func delete(id: UInt32) -> [UInt8] {
    Array("\u{1B}_Ga=d,d=I,q=2,i=\(id)\u{1B}\\".utf8)
  }

  /// La cellule qui montre la case (`row`, `column`) de l'image `id`.
  public static func placeholder(id: UInt32, row: Int, column: Int, background: TerminalColor = .default) -> Cell {
    var grapheme = "\u{10EEEE}"
    grapheme.unicodeScalars.append(diacritic(row))
    grapheme.unicodeScalars.append(diacritic(column))
    let style = Style(
      foreground: .rgb(UInt8((id >> 16) & 0xFF), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)),
      background: background
    )
    return Cell(grapheme: grapheme, style: style, width: 1)
  }

  /// Le plus grand nombre de lignes ou de colonnes qu'un placeholder sait coder.
  public static var maxPlaceholderIndex: Int { diacritics.count - 1 }

  private static func diacritic(_ index: Int) -> Unicode.Scalar {
    let clamped = min(max(0, index), diacritics.count - 1)
    return Unicode.Scalar(diacritics[clamped])!
  }

  /// `rowcolumn-diacritics.txt` du dépôt de Kitty, dans l'ordre : l'indice
  /// d'un diacritique est le numéro de ligne ou de colonne qu'il code.
  private static let diacritics: [UInt32] = [
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A,
    0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365,
    0x0366, 0x0367, 0x0368, 0x0369, 0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F,
    0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
    0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1, 0x05A8, 0x05A9,
    0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
    0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6,
    0x06D7, 0x06D8, 0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
    0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736,
    0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743, 0x0745, 0x0747, 0x0749, 0x074A,
    0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817,
    0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
    0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C, 0x082D, 0x0951,
    0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD,
    0x193A, 0x1A17, 0x1A75, 0x1A76, 0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C,
    0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
    0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4, 0x1DC5, 0x1DC6,
    0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5,
    0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF,
    0x1DE0, 0x1DE1, 0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
    0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0,
    0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2, 0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6,
    0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0,
    0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
    0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1,
    0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9,
    0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED, 0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2,
    0xAAB3, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23,
    0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187, 0x1D188, 0x1D189,
    0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
  ]
}

/// Les autres séquences « de confort » qu'un terminal moderne comprend.
public enum TerminalSequences {
  /// OSC 52 : met du texte dans le presse-papiers du système, même derrière SSH.
  public static func copyToClipboard(_ text: String) -> [UInt8] {
    Array("\u{1B}]52;c;\(Data(text.utf8).base64EncodedString())\u{1B}\\".utf8)
  }

  /// Une notification du bureau portée par le terminal.
  ///
  /// OSC 99 est le protocole de Kitty (titre et corps distincts) ; OSC 9 est
  /// celui d'iTerm2, que Ghostty, WezTerm et foot comprennent. Le terminal
  /// décide seul de l'afficher — Ghostty ne le fait que si sa fenêtre n'a pas
  /// le focus, ce qui est exactement la politique voulue.
  public static func notification(title: String, body: String, kitty: Bool) -> [UInt8] {
    let clean: (String) -> String = { text in
      String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && $0 != ";" || $0.value > 0x7F }.map(Character.init))
    }
    if kitty {
      let identifier = Int.random(in: 1...999_999)
      return Array("\u{1B}]99;i=\(identifier):d=0:p=title;\(clean(title))\u{1B}\\\u{1B}]99;i=\(identifier):d=1:p=body;\(clean(body))\u{1B}\\".utf8)
    }
    return Array("\u{1B}]9;\(clean(title)) — \(clean(body))\u{1B}\\".utf8)
  }

  /// Le titre de la fenêtre ou de l'onglet.
  public static func windowTitle(_ title: String) -> [UInt8] {
    Array("\u{1B}]2;\(title.filter { $0.asciiValue.map { $0 >= 0x20 } ?? true })\u{1B}\\".utf8)
  }
}
