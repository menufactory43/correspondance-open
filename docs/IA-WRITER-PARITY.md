# Parité iA Writer — audit du bundle local

Source : `~/Downloads/iA Writer.app` (v8.0.6, build 80046)  
+ préférences utilisateur `pro.writer.mac`  
+ frameworks `TypographyKit`, `Kit`

## Ce qu’ils ont (et qui nous manque)

### 1. Familles typographiques (cœur)

| Famille | Rôle | Licence | Chez nous |
| --- | --- | --- | --- |
| **iA Writer Mono** | Manuscrit monospace | SIL OFL | ❌ |
| **iA Writer Duo** | Duospaced (demi-chasse) | SIL OFL | ❌ |
| **iA Writer Quattro** | Proportionnelle « Writer » | SIL OFL | ❌ |
| **IBM Plex Sans** | Template Sans | SIL OFL | ❌ |
| **IBM Plex Serif** | Template Serif | SIL OFL | ❌ |
| iA Writer Emphasis* | Marques d’emphase CJK | SIL OFL | ❌ (v2) |
| New York / system serif | — | — | ✅ (actuel) |

Fichiers dans le bundle : `Contents/Resources/Fonts/Core-Variable/{Mono,Duo,Quattro}` + `Additional/IBMPlex*`.

### 2. Templates d’écriture (= « look » de page)

`Mono` · `Duo` · `Quattro` · `Sans` · `Serif` · `GitHub`  
Chacun : `max-width ≈ 37.5–38em`, métriques de leading précises, night-mode CSS.

### 3. Mode Focus — réglages (priorité haute)

Préférences / code observés :

| Réglage | Clé / symbole | Valeurs |
| --- | --- | --- |
| Focus on/off | `Editor Focus Mode` | bool |
| **Champ d’application** | `Editor Focus Scope` | **Phrase** / **Paragraphe** / Text |
| Atténuation hors focus | `_addDimmingInRange:focusRange:` | alpha sur le reste |
| **Machine à écrire** | `typewriterScrollingEnabled` | centre le caret verticalement |
| Emphase | `changeEmphasis:` | italic / mark / … |

Toolbar : segmented control Focus + menus.

### 4. Réglages éditeur (EditorPreferences)

Français dans le nib :

- **Police d’écriture** (Mono / Duo / Quattro / …)
- **Taille du texte**
- **Longueur de ligne maximum** : 64 / 72 / 80 **caractères par ligne**
- **Machine à écrire**
- **Emphase**
- Syntaxe / style checking (adverbes, fillers…) — hors scope Correspondance
- Orthographe / typographie / tirets / citations

### 5. Apparence générale

- Clair / Sombre / Assortir au système  
- Barre d’outils : Masquer / Toujours afficher / Fondu  
- Inversion couleurs night dans l’aperçu

### 6. Hors parité voulue (on ignore)

Bibliothèque cloud, preview split HTML, authorship rainbow, Mermaid, publication, style-checking NLP, KaTeX preview, Word export, templates marketplace.

## Priorité d’implémentation Correspondance

1. **Polices OFL** : Mono, Duo, Quattro (+ Plex Serif/Sans optionnels)  
2. **Réglages Focus** : portée Phrase/Paragraphe + atténuation  
3. **Machine à écrire** : caret centré verticalement  
4. **Largeur** : 64 / 72 / 80 cpl (ou em)  
5. **Taille du texte** déjà partiellement là via `typeScale` — brancher sur l’éditeur  
6. Sélecteur de famille dans Réglages / chrome Focus

## Notes légales

Les familles iA Writer Mono/Duo/Quattro et IBM Plex sont **SIL OFL 1.1** : redistribution OK avec `OFL.txt` et copyright.  
Ne pas embarquer le binaire commercial ; préférer GitHub `iaolo/iA-Fonts` + IBM/plex.
