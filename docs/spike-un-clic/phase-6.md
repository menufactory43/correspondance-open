# Phase 6 — Les binaires que nous construisons, les deux cartes, la publication préparée

Éprouvé le 2 septembre 2026, sur le Mac de développement (arm64, macOS 26.6.2). Tout vit sous
`~/.correspondance-unclic/` (le Relais), `~/.correspondance-unclic-src/` (les sources) et
`~/unclic-publication/` (ce qui serait publié). Aucune build par le DerivedData par défaut, aucun
compte réel lié, rien poussé sur GitHub.

**Verdict** : *les quatre ponts sont désormais les nôtres, en Olm de Go pur, et libolm a quitté la
pile ; l'installeur parle une langue de machine ; et l'app pose un Relais complet en **26 secondes,
d'un clic, sans qu'on tape une seule touche**.* Reste un trou dit franchement : pas de
`mautrix-signal-linux-amd64` sans conteneur.

| Livrable | Verdict |
|---|---|
| **A** — binaires reproductibles, goolm | **fait**, sauf Signal pour Linux (libsignal en cgo) |
| **B** — `install.sh --json` | **fait**, dix étapes + l'appairage, couvert par `install-plan.sh` |
| **C** — les deux cartes dans l'app | **fait**, prouvé de bout en bout avec captures |
| **D** — publication préparée, non faite | **fait**, avec la mesure Gatekeeper réelle |

---

## A. Les binaires que nous construisons

`infra/relais/construire.sh` reconstruit tout depuis les sources épinglées et dépose le résultat
dans un dossier de publication, avec un `SHA256SUMS`. Il demande Go, cargo, git — c'est un outil de
**construction**, jamais une partie de la pile livrée. `install.sh`, lui, ne construit rien.

```
bash infra/relais/construire.sh                       # tout
bash infra/relais/construire.sh --quoi ponts          # les quatre ponts
bash infra/relais/construire.sh --quoi continuwuity   # le homeserver macOS
bash infra/relais/construire.sh --quoi sommes         # régénère SHA256SUMS et copie les scripts
```

### Ce qu'il a fallu poser sur la machine de construction

`brew install go` (go1.27.1), `brew install zig` (0.16.0, le compilateur C croisé) et
`brew install protobuf` (libprotoc 36.0, exigé par `spqr`, une dépendance de libsignal). Aucun des
trois n'entre dans le produit.

### Les mesures

```
$ cat ~/unclic-publication/construction.log
continuwuity-macos-arm64               12m04s      80749216 o  3851299c…6ce2ff9
mautrix-whatsapp-darwin-arm64           0m22s      30224594 o  0b4d4bde…f769b11
mautrix-instagram-darwin-arm64          0m06s      31073842 o  763f1cab…1254b31
mautrix-meta-darwin-arm64               0m06s      35227554 o  bad1ef2d…6d3af5f1
mautrix-signal-darwin-arm64            32m55s      54245938 o  d85c48ff…e846f6f4
mautrix-whatsapp-linux-amd64            2m06s      45512360 o  a6b1dd50…489c7985
mautrix-instagram-linux-amd64           0m11s      44053952 o  81f79296…e2691472
mautrix-meta-linux-amd64                0m07s      49112808 o  b2e87ffc…6095b0dc
```

(Les durées des ponts sont celles d'une construction **à froid** ; relancés, le cache de Go les
rend en une à cinq secondes. Les 32m55s de Signal sont presque entièrement libsignal — un
sous-module Rust de ~100 Mo d'archive statique, qui télécharge au passage une toolchain nightly.)

### Trois choses qui ne se voyaient qu'en construisant

**1. `CGO_ENABLED=0` ne marche pas, et goolm n'y change rien.** C'était l'hypothèse du plan.
goolm retire bien la seule dépendance C que nous visions — libolm — mais deux autres restent :

```
# go.mau.fi/webp
webp.go:39:20: undefined: webpDecodeRGB
# maunium.net/go/mautrix/bridgev2/matrix/mxmain
dberror.go:64:27: undefined: sqlite3.Error
```

`mattn/go-sqlite3` est la base de chaque pont, `go.mau.fi/webp` fait les vignettes. cgo est donc
obligatoire, et croiser vers Linux demande un compilateur C croisé. `zig cc -target
x86_64-linux-musl` en tient lieu — une commande, pas une chaîne à monter — et rend des ELF
statiques :

```
$ file ~/unclic-publication/mautrix-whatsapp-linux-amd64
ELF 64-bit LSB executable, x86-64, statically linked, Go BuildID=…
```

**2. Signal ne se croise pas sans conteneur.** libsignal est du Rust exposé en C et lié
statiquement. Croiser demanderait *à la fois* une cible Rust `x86_64-unknown-linux-musl` et le
linker C croisé, c'est-à-dire reconstruire libsignal en entier pour Linux. `construire.sh` le dit
et passe :

```
   (mautrix-signal-linux-amd64 : non construit — libsignal est en cgo, croiser
    demande un conteneur ; voir phase-6.md)
```

Conséquence : `install.sh` garde les releases amont pour Linux, dont les binaires statiques
tournent sur le NUC depuis la phase 3. Les trois ponts Linux goolm existent et sont publiables,
mais basculer dessus sans les avoir posés sur une machine Linux serait exactement le genre de
changement non vérifié que ce spike refuse.

**3. Continuwuity n'est pas reproductible au bit près.** Même tag, même ligne `cargo`, même
version affichée, **même taille à l'octet** — et 3 474 918 octets de différence avec le binaire de
la phase 1 :

```
$ shasum -a 256 /tmp/continuwuity-phase1-arm64 ~/unclic-publication/continuwuity-macos-arm64
a7b4dd20…16f77  (phase 1)
3851299c…2ff9   (phase 6)
$ ~/unclic-publication/continuwuity-macos-arm64 --version
continuwuity 26.8.1 (ab3c05d)
$ cmp -l … | wc -l
 3474918
```

Le dossier de construction a changé de nom entre les deux phases, et son chemin absolu est
embarqué dans le binaire. La somme est donc **relevée à chaque construction**, jamais supposée —
et c'est aussi pour ça que `SHA256SUMS` est régénéré par le même script qui construit.

### La preuve : libolm a quitté la pile

```
$ otool -L ~/unclic-publication/mautrix-signal-darwin-arm64
	/usr/lib/libSystem.B.dylib
	/usr/lib/libz.1.dylib
	/usr/lib/libc++.1.dylib
	/usr/lib/libresolv.9.dylib
	/System/Library/Frameworks/CoreFoundation.framework/…
	/System/Library/Frameworks/Security.framework/…
```

Aucun `@rpath/libolm.3.dylib`. Les trois autres ponts n'ont même pas `libz`/`libc++` (ils sont
sans libsignal). `install.sh` ne pose plus de dylib du tout : `OLM_URL=""` sur les trois hôtes, et
`tests/install-plan.sh` interdit désormais le mot « libolm » dans le plan macOS.

### Et le chiffrement tient toujours

Installation complète depuis `~/unclic-publication` servi en local, puis :

```
$ for bot in whatsappbot signalbot instagrambot messengerbot; do
    python3 infra/relais-spike/eprouver-ponts.py http://127.0.0.1:8010 "$J" unclic.local "$bot" help
  done
Hello, I'm a WhatsApp bridge bot.        Use `help` for help or `login` to log in.
Hello, I'm a Signal bridge bot.          Use `help` for help or `login` to log in.
Hello, I'm a Instagram bridge bot.       Use `help` for help or `login` to log in.
Hello, I'm a Facebook Messenger bridge bot.  Use `help` for help or `login` to log in.
```

Et la preuve qui compte vraiment — les quatre bots ont **publié des clés Olm**, donc la machine
crypto en Go pur fonctionne :

```
$ curl … /_matrix/client/v3/keys/query -d '{"device_keys":{…}}'
@whatsappbot:unclic.local   ['WMHNc183fR']  [['m.megolm.v1.aes-sha2', 'm.olm.v1.curve25519-aes-sha2']]
@signalbot:unclic.local     ['0cR40EsBJC']  [['m.megolm.v1.aes-sha2', 'm.olm.v1.curve25519-aes-sha2']]
@instagrambot:unclic.local  ['YIQCjM0DN4']  [['m.megolm.v1.aes-sha2', 'm.olm.v1.curve25519-aes-sha2']]
@messengerbot:unclic.local  ['YbaNHRxT17']  [['m.megolm.v1.aes-sha2', 'm.olm.v1.curve25519-aes-sha2']]
```

Les salons de gestion, eux, ne portent pas `m.room.encryption` — c'est le comportement de
bridgev2, qui chiffre les **portails** et pas le salon de commande. Aucun portail n'existe ici :
la règle du spike interdit de lier un compte réel, et la configuration reste `allow: true,
default: true` comme depuis la phase 4.

---

## B. L'installeur en mode machine

`install.sh --json` émet une ligne JSON par étape, et le code d'appairage comme **dernier objet**.
Les phrases pour l'humain continuent de sortir dans le même tuyau : un installeur muet en mode
humain serait une seconde chose à éprouver, et l'analyseur ignore ce qui n'est pas un objet du
protocole.

```
$ CORRESPONDANCE_RELEASES=http://127.0.0.1:8020 bash infra/relais/install.sh --json | grep '^{'
{"etape": "prerequis", "etat": "debut", "detail": "curl, python3, sha256 — aucun sudo, aucun Docker"}
{"etape": "prerequis", "etat": "ok", "detail": "macos-arm64 — tout vit sous /Users/…/.correspondance-unclic"}
{"etape": "binaires", "etat": "debut", "detail": "continuwuity v26.8.1 et les ponts mautrix v0.2608.0, sha256 vérifié"}
{"etape": "binaires", "etat": "ok", "detail": "posés dans …/bin, toutes les sommes conformes"}
{"etape": "secrets", "etat": "debut", "detail": "tirés une fois, jamais réécrits"}
{"etape": "secrets", "etat": "ok", "detail": "…/secrets.env (0600)"}
{"etape": "configuration", "etat": "debut", "detail": "unclic.local, écoute 127.0.0.1:8010"}
{"etape": "configuration", "etat": "ok", "detail": "…/relais/continuwuity.toml"}
{"etape": "services", "etat": "debut", "detail": "launchd"}
{"etape": "services", "etat": "ok", "detail": "le Relais est un service launchd : il revient au démarrage de la session"}
{"etape": "attente", "etat": "debut", "detail": "http://127.0.0.1:8010"}
{"etape": "attente", "etat": "ok", "detail": "{\"name\":\"continuwuity\",\"version\":\"26.8.1 (ab3c05d)\"}"}
{"etape": "compte", "etat": "debut", "detail": "@essai:unclic.local"}
{"etape": "compte", "etat": "ok", "detail": "@essai:unclic.local"}
{"etape": "ponts", "etat": "debut", "detail": "WhatsApp, Signal, Instagram, Messenger — portails chiffrés"}
{"etape": "ponts", "etat": "ok", "detail": "quatre ponts enregistrés et démarrés (29318, 29328, 29330, 29331)"}
{"etape": "preuve", "etat": "debut", "detail": "/login puis /account/whoami"}
{"etape": "preuve", "etat": "ok", "detail": "connecté comme @essai:unclic.local"}
{"etape": "appairage", "etat": "ok", "code": "correspondance://relais/eyJleHAiOjE3…", "mots": ["usine", "marée", "dune", "chêne", "zeste", "encre"]}
durée totale : 14 s
```

**14 secondes** depuis un préfixe vide, binaires servis en local — contre 16 s en phase 4 avec
libolm à poser en plus.

Deux décisions qui ne sont pas cosmétiques :

- `mourir()` émet l'échec **dans le flux** (`{"etape":"<courante>","etat":"erreur",…}`) avant de
  sortir. Sans ça l'app voit le processus mourir et n'a que « code 1 » à dire, alors que
  l'installeur, lui, savait sur quoi il butait.
- La fin se reconnaît au champ `code`, pas au nom de l'étape. Une étape nommée « appairage » sans
  code ferait croire à l'app qu'elle est prête, et elle n'attendrait plus rien.

`tests/install-plan.sh` couvre le mode : les dix étapes annoncées et conclues, l'échec dans le
flux, la fin reconnaissable, et il **fait parler** la fonction `etape` plutôt que de la lire.

```
$ bash infra/relais/tests/install-plan.sh | tail -4
  ✓ une étape émise est bien du JSON
  ✓ un détail vide reste un champ

Plan d'installation du Relais : tout est conforme.
```

---

## C. Les deux cartes

`Correspondance/Features/Accueil/AccueilRelaisView.swift`, montrée par `ContentView` à la place de
l'inbox quand il manque un Relais. `Correspondance/Services/RelaisInstallation.swift` tient le
téléchargement, la vérification et le processus enfant.

![L'écran d'accueil](phase-6-accueil.png)

Il n'y a que deux cartes, parce qu'il n'y a que deux endroits où poser un Relais. Pas de carte
« hébergé » : nous n'hébergeons rien. Aucune question sur le chiffrement : il est d'office depuis
la phase 5, et le proposer laisserait croire qu'on peut répondre non.

### « Installer ici », de bout en bout

L'app va chercher `SHA256SUMS` puis `relais-install.sh` à `CORRESPONDANCE_RELEASES`, **compare la
somme avant d'exécuter quoi que ce soit**, lance le script en `bash … --json` comme processus
enfant, et lit sa sortie ligne par ligne.

![Les étapes qui défilent](phase-6-etapes.png)

À la dernière ligne, elle colle le code elle-même — `RelayPairingCode(encoded:)` puis
`connectMatrix`, c'est-à-dire exactement le chemin du champ des réglages, sans le copier-coller.

![Connectée, la note à soi](phase-6-connectee.png)

**26 secondes du clic à la note à soi visible.** Rien n'a été tapé : ni adresse, ni identifiant, ni
mot de passe, ni code. (La liste des conversations est recadrée : ce Mac porte de vraies
conversations iMessage.)

![Le fil de la note à soi](phase-6-note-a-soi.png)

### Deux choses qui ne se sont vues qu'à l'exécution

**La condition d'affichage ne peut pas être « l'inbox est vide ».** Au premier essai, l'écran
d'accueil n'est jamais apparu : ce Mac a des conversations iMessage dès le premier lancement.
Elle ne peut pas non plus être « déconnecté » tout court — une coupure passagère escamoterait des
fils déjà synchronisés, qui se lisent hors ligne. Ce qu'on regarde, c'est s'il existe **une seule
conversation qui vienne d'un Relais** :

```swift
!store.isMatrixConnected && !store.conversations.contains { $0.network.livesOnRelay }
```

**« Tout retirer » n'aurait vécu que dix secondes.** Il n'était affiché qu'en phase `.fini`,
c'est-à-dire entre la fin de l'installation et la connexion qui fait disparaître l'écran
d'accueil — après quoi il devenait inatteignable. Il s'affiche désormais sur la **marque** que
`install.sh` écrit et que `uninstall.sh` exige avant d'effacer quoi que ce soit :

![« Tout retirer » sur un Relais déjà posé](phase-6-tout-retirer.png)

Cliqué pour de vrai, depuis l'app :

```
$ launchctl list | grep correspondance      # (rien)
$ ls -d ~/.correspondance-unclic
ls: /Users/…/.correspondance-unclic: No such file or directory
$ curl -m 2 http://127.0.0.1:8010/_matrix/client/versions
ne répond plus
```

### Les tests

Quinze tests sur les deux parties pures, `CorrespondanceTests/RelaisInstallationTests.swift` :

```
$ CORRESPONDANCE_CRYPTO=1 xcodebuild test … -only-testing:CorrespondanceTests/RelaisInstallationTests
Test Suite 'RelaisInstallationTests' passed.
	 Executed 15 tests, with 0 failures (0 unexpected) in 0.055 seconds
** TEST SUCCEEDED **
```

L'analyse du flux : une ligne pour l'humain ne casse rien, un état inconnu n'est pas une étape,
une étape `debut` puis `ok` ne compte qu'une fois dans la liste, la fin se reconnaît au champ
`code`. Le sha256 : les deux formats de `shasum` (`  nom` et ` *nom`), un commentaire qui n'est
pas une somme, un fichier absent du `SHA256SUMS`, un octet de différence.

Le champ du code reste dans **Réglages › Matrix**, inchangé, et la carte « machine à moi » en
porte un second avec les six mots.

---

## D. La publication, préparée sans être faite

`infra/relais/publier.sh --dry-run`. Le défaut est de ne rien pousser ; `--vraiment` est explicite,
et c'est une décision du propriétaire.

```
$ bash infra/relais/publier.sh --dry-run
Publication du Relais Correspondance
  dossier   /Users/…/unclic-publication
  dépôt     menufactory43/correspondance-releases
  tag       relais-2026.09.02

Les fichiers, et leurs sommes
  continuwuity-macos-arm64               80749216 o  3851299c…2ff9
  mautrix-instagram-darwin-arm64         31073842 o  763f1cab…4b31
  mautrix-instagram-linux-amd64          44053952 o  81f79296…1472
  mautrix-meta-darwin-arm64              35227554 o  bad1ef2d…f5f1
  mautrix-meta-linux-amd64               49112808 o  b2e87ffc…b0dc
  mautrix-signal-darwin-arm64            54245938 o  d85c48ff…f6f4
  mautrix-whatsapp-darwin-arm64          30224594 o  0b4d4bde…9b11
  mautrix-whatsapp-linux-amd64           45512360 o  a6b1dd50…7985
  relais-install.sh                         37173 o  6eb1713e…07e1
  relais-uninstall.sh                        2317 o  98e24a8f…86ec

SHA256SUMS
  ✓ (dix fichiers, dans les deux sens : aucune somme orpheline, aucun fichier sans somme)

Ce qu'une publication exécuterait
  gh release view relais-2026.09.02 --repo menufactory43/correspondance-releases
  gh release create relais-2026.09.02 --repo … --title 'Relais relais-2026.09.02' --notes-file …/NOTES.md
  gh release upload relais-2026.09.02 --repo … --clobber '…/continuwuity-macos-arm64' … '…/SHA256SUMS'

(--dry-run : rien n'a été poussé. Publier : --vraiment, et c'est une décision.)
```

Total à publier : **410 Mio**, dont 80,7 pour Continuwuity.

### Signature et notarisation

Une identité « Developer ID Application » **existe** sur cette machine. Ce qu'il faudrait, binaire
par binaire — les ponts amont ne sont pas signés, et les republier chez nous est justement ce qui
permet de le faire :

```
codesign --force --options runtime --timestamp --sign "Developer ID Application: … (…)" <binaire>
ditto -c -k --keepParent <binaire> <binaire>.zip
xcrun notarytool submit <binaire>.zip --keychain-profile <profil> --wait
```

Le piège : **un binaire nu ne peut pas être agrafé.** `xcrun stapler` n'agrafe que des paquets
(`.app`, `.dmg`, `.pkg`). Le ticket de notarisation reste donc en ligne, et Gatekeeper le demande
au premier lancement — une machine hors réseau évaluera le binaire sans lui.

### Gatekeeper : ce qui se passe vraiment, mesuré

C'était une vraie question. La réponse tient en deux mesures.

**Un binaire ad-hoc portant `com.apple.quarantine` est tué au `exec`, en silence :**

```
$ codesign -dv mautrix-whatsapp-darwin-arm64
CodeDirectory v=20400 flags=0x20002(adhoc,linker-signed)
$ xattr -w com.apple.quarantine "0083;…;Correspondance;…" avec-quarantaine
$ ./avec-quarantaine --version
$ echo $?
137                      # 128 + 9 : SIGKILL, aucune ligne sur stderr
$ ./sans-quarantaine --version
mautrix-whatsapp v26.08 (built at Wed, 02 Sep 2026 12:23:21 CEST with go1.27.1)
$ spctl -a -vv -t exec sans-quarantaine
rejected
```

Un code 137 sans un mot est exactement le genre de panne qui coûte une soirée. C'est le « sans ça
le binaire est tué » que l'installeur contourne depuis la phase 3 par `xattr -d`.

**Mais l'attribut n'apparaît pas tout seul.** Ni `curl`, ni `URLSession` suivie d'un `write(to:)`
ne le posent — seuls les téléchargeurs qui passent par LaunchServices (navigateur, Mail, AirDrop)
le font :

```
$ xattr -l /var/folders/…/T/correspondance-relais/relais-install.sh   # écrit par l'app
com.apple.provenance:                                                 # et rien d'autre
$ curl -fsSLO http://127.0.0.1:8020/relais-install.sh && xattr -l relais-install.sh
com.apple.provenance:
```

**Donc : un binaire non signé téléchargé par l'app et lancé en processus enfant n'est pas bloqué
aujourd'hui** — l'installation par la carte l'a prouvé de bout en bout. Ça ne dispense pas de
signer : `spctl -a -t exec` rejette déjà ces binaires, et il suffirait d'un bac à sable, ou d'un
durcissement de macOS étendant la quarantaine aux fichiers écrits par une app, pour que tout
tombe d'un coup, en silence, chez tout le monde.

---

## Les mesures, ensemble

| | Phase 4 (libolm) | Phase 6 (goolm) |
|---|---|---|
| Installation, préfixe vide | 16 s | **14 s** |
| Fichiers posés sur macOS | 5 binaires + 1 dylib | **5 binaires** |
| « Installer ici » dans l'app | — | **26 s, zéro frappe** |
| Construction de Continuwuity | ~20 min (phase 1) | **12 min 04 s** |
| Construction des quatre ponts macOS | — | **33 min 29 s** (dont 32 min 55 s pour libsignal) |
| Trois ponts Linux amd64 croisés | — | **2 min 24 s** |
| Poids de la publication | — | **410 Mio** |

---

## Rejouer les preuves

```
cd ~/correspondance-un-clic

# A — construire (long : ~45 min à froid, ~13 min sans Signal)
bash infra/relais/construire.sh --quoi ponts --cibles "darwin-arm64 linux-amd64"
bash infra/relais/construire.sh --quoi continuwuity
otool -L ~/unclic-publication/mautrix-signal-darwin-arm64      # aucun libolm

# B — le plan et le mode machine (ne touche à rien)
bash infra/relais/tests/install-plan.sh

# A + B — une installation complète depuis notre publication
cd ~/unclic-publication && python3 -m http.server 8020 --bind 127.0.0.1 &
cd ~/correspondance-un-clic
CORRESPONDANCE_RELEASES=http://127.0.0.1:8020 bash infra/relais/install.sh --json
J=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["access_token"])' ~/.correspondance-unclic/proprietaire.json)
for b in whatsappbot signalbot instagrambot messengerbot; do
  python3 infra/relais-spike/eprouver-ponts.py http://127.0.0.1:8010 "$J" unclic.local "$b" help
done

# C — l'app, et la carte « Sur ce Mac »
CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Debug -derivedDataPath /tmp/dd-unclic build
CORRESPONDANCE_CRYPTO=1 xcodebuild test -project Correspondance.xcodeproj -scheme Correspondance \
  -destination 'platform=macOS' -derivedDataPath /tmp/dd-unclic \
  -only-testing:CorrespondanceTests/RelaisInstallationTests
CORRESPONDANCE_HOME=unclic CORRESPONDANCE_RELEASES=http://127.0.0.1:8020 \
  /tmp/dd-unclic/Build/Products/Debug/Correspondance.app/Contents/MacOS/Correspondance

# D — la publication, et Gatekeeper
bash infra/relais/publier.sh --dry-run

# Ne rien laisser
bash infra/relais/uninstall.sh
kill %1                                        # le serveur local
```

Les tests du paquet, inchangés : **798** sans crypto, **803** avec
(`CORRESPONDANCE_CRYPTO=1 swift test --scratch-path /tmp/build-unclic-crypto`).

---

## Ce qui reste

1. **`mautrix-signal-linux-amd64`.** Il faut un conteneur Linux (ou une machine Linux de build) pour
   reconstruire libsignal pour cette cible. Une demi-journée, sur une machine qui n'est pas le NUC
   de production.
2. **Basculer `install.sh` sur les ponts Linux goolm**, une fois posés et éprouvés sur une machine
   Linux — les trois binaires existent déjà.
3. **Signer et notariser** les huit binaires, et décider où atterrit un ticket qu'on ne peut pas
   agrafer.
4. **Publier**, c'est-à-dire `publier.sh --vraiment` — une décision du propriétaire.
5. La carte « Sur ce Mac » suppose une app **hors bac à sable** : elle lance un script qui pose des
   `LaunchAgents`. Correspondance se distribue déjà en DMG notarisé hors App Store, donc c'est
   cohérent, mais c'est un engagement à écrire noir sur blanc.
