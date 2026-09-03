# Correspondance pour Linux

Le même cœur que le Mac et l'iPhone — client Matrix, magasin local SQLite, état de
conversation du Relais, chiffrement de bout en bout — dans **un binaire statique**
(`x86_64`, musl), sans dépendance. L'interface est la nôtre, servie sur `127.0.0.1`
au navigateur que le bureau ouvre : Focus, Inbox, les six thèmes d'écriture, les
polices iA Writer, les mêmes raccourcis.

Linux est, comme l'iPhone, un **client Relais pur** : Signal, WhatsApp, Instagram et
Messenger passent par le Relais ; iMessage n'existe que sur un Mac, et arrive ici s'il
y en a un branché au même Relais.

## Installer

```sh
curl -fsSL https://correspondance.app/linux -o Correspondance-linux.tar.gz
tar xzf Correspondance-linux.tar.gz
cd Correspondance-*-linux-x86_64 && ./install.sh
correspondance
```

Tout va dans `~/.local` (binaire, interface, entrée de menu, icône). `./install.sh --uninstall`
retire tout et garde les données (`~/.local/share/Correspondance`).

## Se connecter

Au premier lancement, la page demande le **code d'appairage** que l'installeur du
Relais affiche (`correspondance://relais/…`), ou l'adresse + identifiant + mot de
passe. La session est gardée dans `~/.local/share/Correspondance/secrets.json` (droits
`0600`) — c'est le Trousseau de Linux.

Il faut être sur le réseau du Relais : Tailscale, ou l'adresse locale. Le chemin
Tailcat (WireGuard sans compte) n'est pas encore porté ici.

## Ce qui n'y est pas (encore)

- Les messages vocaux **enregistrés** (pas de micro ni d'encodeur Opus dans un binaire
  statique) ; ceux qu'on reçoit s'écoutent.
- La dictée, la barre des menus, le partage depuis les autres apps, les fenêtres
  détachées — des affaires de macOS.
- L'agent « cc » lancé en un clic depuis les réglages ; on l'active sur le Relais.

## Construire depuis ce Mac

```sh
scripts/release-linux.sh     # binaire statique + interface + polices → build/release/*.tar.gz
scripts/publish-linux.sh     # → GitHub, release linux-latest (le lien du site)
```

Il faut la chaîne swift.org 6.3.3 (`~/Library/Developer/Toolchains`), le SDK statique
Linux (`swift sdk list` → `static-linux`) et, pour le chiffrement, la bibliothèque
crypto croisée (`infra/relais/crypto-linux.sh`).

Pour l'essayer sur le Mac lui-même (le même code, Foundation partout) :

```sh
cd Packages/CorrespondanceCore
CORRESPONDANCE_HOME=essai swift run correspondance-linux --ui ../../linux/ui
```
