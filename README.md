# Correspondance

> Inbox Focus pour **iMessage**, **Signal**, **WhatsApp**, **Instagram** et **Messenger** (dogfood).
> Spec : [`docs/PRODUCT.md`](docs/PRODUCT.md) · agent « cc » : [`docs/AGENT.md`](docs/AGENT.md) · les deux derniers passent par des ponts mautrix,
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
5. Signal / WhatsApp / Instagram / Messenger : pile Matrix sur le NUC (`./infra/matrix/bootstrap.sh`), puis
   Réglages › Matrix — QR à scanner pour Signal et WhatsApp, fenêtre de connexion pour Instagram
   (instagram.com) et Messenger (facebook.com).

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

### Essayer sans toucher à ses vraies conversations

`CORRESPONDANCE_HOME` déplace **d'un bloc** le dossier de données et l'entrée du Trousseau :

```bash
CORRESPONDANCE_HOME=essai open -a Correspondance
# ou, depuis Xcode : Product › Scheme › Edit Scheme › Run › Arguments › Environment Variables
```

| | Sans la variable | `CORRESPONDANCE_HOME=essai` |
| --- | --- | --- |
| Données | `~/Library/Application Support/Correspondance` | `…/Correspondance-essai` |
| Session Matrix (Trousseau) | `app.correspondance.matrix` | `app.correspondance.matrix.essai` |

Les deux bougent ensemble, jamais l'une sans l'autre : une base déplacée avec le Trousseau
d'origine écraserait la vraie session au premier appairage. C'est le symétrique de
`CORRESPONDANCE_AGENT_HOME`, qui déplace l'amorce d'un agent depuis toujours.

**Sans la variable, rien ne change** — mêmes chemins qu'avant, au caractère près. Réglages ›
Matrix affiche un encart « Essai » quand elle est posée, pour qu'on ne croie jamais regarder
ses vraies conversations. Pour tout effacer : supprimer `…/Correspondance-essai` et l'entrée
`app.correspondance.matrix.essai` du Trousseau.

La marche à suivre complète (Relais d'essai, appairage, agent, MCP) est dans
`docs/MATRIX-SETUP.md` § « Essayer de bout en bout ».

## Linux

Le même cœur, en binaire statique `x86_64`, l'interface servie au navigateur sur `127.0.0.1` :
`linux/README.md`. Construire et publier depuis ce Mac : `scripts/release-linux.sh` puis
`scripts/publish-linux.sh` (release `linux-latest`, lien `/linux` du site). L'essayer ici même :

```bash
cd Packages/CorrespondanceCore
CORRESPONDANCE_HOME=essai swift run correspondance-linux --ui ../../linux/ui
```

## Dictée

Le micro du composer passe par **[Dictus](https://www.getdictus.com)** (libre, MIT, transcription 100 % locale) s'il est installé dans `/Applications` — Correspondance le pilote par sa CLI (`--toggle-transcription` / `--cancel`), Dictus colle le texte dans le champ. Désactivable dans Réglages → Dictée ; sans Dictus, la reconnaissance vocale d'Apple prend le relais.

## Thèmes

Six ambiances (papier / dune / clair de lune / encre de nuit / vieux bureau / cire et chêne) dans Réglages.

## Raccourcis

- ⌘1 Focus · ⌘2 Inbox
- ⌘↑ / ⌘↓ conversation précédente / suivante
- ⌘E archiver
- ⌘R actualiser

## Livrer le Mac

`scripts/release-mac.sh` fabrique le DMG : archive Release arm64 avec le chiffrement,
export Developer ID par Xcode (compte de l'équipe connecté), notarisation avec le profil
`notarisation` du Trousseau, ticket agrafé sur l'app puis sur le DMG. `NOTARIZE=0` pour une
build signée sans l'aller-retour Apple. Le résultat est dans `build/release/`.
