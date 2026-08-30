# Correspondance

> Inbox Focus pour **iMessage**, **Signal**, **WhatsApp** et **Instagram** (dogfood).
> Spec : [`docs/PRODUCT.md`](docs/PRODUCT.md) · les deux derniers passent par des ponts mautrix,
> voir [`docs/MATRIX-SETUP.md`](docs/MATRIX-SETUP.md).

Deux modes :

| Mode | Raccourci | Rôle |
| --- | --- | --- |
| **Focus** (défaut) | ⌘1 | Page zen : transcript + composer. Chrome au survol (haut). |
| **Inbox** | ⌘2 | **Sidebar** liste + fil (type Beeper). |

En Focus tu ne vois pas la sidebar — c’est voulu. Passe en Inbox (⌘2) pour la liste.

## Ouvrir / compiler

```bash
cd correspondance
xcodegen generate
open Correspondance.xcodeproj
```

Puis ⌘R. macOS 14+, Xcode récent.

## Première utilisation

1. Lance l’app — sans accès disque tu verras des conversations **démo**.
2. Réglages Système → Confidentialité → **Accès complet au disque** → autorise **une seule fois** `/Applications/Correspondance.app` (ou le build Xcode).
3. Actualise (⌘R ou bouton) pour lire `~/Library/Messages/chat.db`.
4. L’envoi iMessage passe par l’app **Messages** (AppleScript) — accorde Automation si macOS le demande.
5. Signal : `signal-cli` + `signal-cli link -n Correspondance`.
6. WhatsApp / Instagram (facultatif) : pile Matrix sur le NUC (`./infra/matrix/bootstrap.sh`), puis
   Réglages › Matrix — QR pour WhatsApp, cookies pour Instagram.

### Accès disque qui « saute » à chaque rebuild

Cause : signature **ad hoc**. macOS lie TCC au hash du binaire → chaque rebuild = « nouvelle app ».

Correctif (déjà dans `project.yml`) : signature **Apple Development** + `DEVELOPMENT_TEAM=AKMNXGVVGX`. TCC suit le **bundle id + team**, pas le hash.

Après un rebuild :
```bash
xcodegen generate
xcodebuild -scheme Correspondance -configuration Debug -allowProvisioningUpdates build
# Optionnel : mettre à jour /Applications SANS changer d’identité
rm -rf /Applications/Correspondance.app
cp -R ~/Library/Developer/Xcode/DerivedData/Correspondance-*/Build/Products/Debug/Correspondance.app /Applications/
```
Vérifie `codesign -dv /Applications/Correspondance.app 2>&1 | grep TeamIdentifier` → doit afficher `AKMNXGVVGX`, pas `not set`.

## Thèmes

Six ambiances (papier / dune / clair de lune / encre de nuit / vieux bureau / cire et chêne) dans Réglages.

## Raccourcis

- ⌘1 Focus · ⌘2 Inbox
- ⌘↑ / ⌘↓ conversation précédente / suivante
- ⌘E archiver
- ⌘R actualiser
