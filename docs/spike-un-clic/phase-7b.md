# Phase 7b — Tailcat par défaut

2 septembre 2026. Décision du propriétaire prise après la phase 7a : **Tailcat par
défaut**. Trois livrables, chacun commis avec ses preuves. Rien ici n'est une
lecture : tout a tourné sur ce Mac et sur le NUC, sous des dossiers à part,
sans toucher la production, et sans piloter l'écran.

| Livrable | Verdict |
|---|---|
| 1. L'installeur pose Tailcat sur Linux | **fait** — NUC depuis `~/unclic` vide en 34 s, le code porte le jeton, `curl --socks5-hostname` atteint le Relais sans tunnel ssh |
| 2. Le mandataire dans l'app, prêt à livrer | **fait** — embarqué dans `Contents/Helpers`, signé séparément, relancé s'il tombe ; preuve par un test d'intégration qui fait `/versions` puis `/login` par `TailcatProxy` |
| 3. La carte et les textes | **fait** — la phrase de la carte, `MATRIX-SETUP.md`, `PLAN-relais-un-clic.md`, `CONCLUSION.md` |

Tests : **838** sans la crypto, **843** avec, **1 ignoré** dans les deux cas (la
preuve d'intégration, qui exige une machine distante et un jeton de quinze
minutes). Les deux cibles Xcode compilent.

---

## Le renversement, en une phrase

Avant : *le Relais n'écoute que sur `127.0.0.1`, donc pose Tailscale (compte,
tailnet, extension système, sudo) ou retape `ssh -N -L`.*
Après : *le Relais n'écoute que sur `127.0.0.1`, et l'installeur pose devant lui
un Tailcat que personne n'a à configurer ; le code d'appairage porte son jeton,
et le Mac s'y connecte tout seul.*

Ce qui **ne** change **pas** : l'iPhone. `Process` n'existe pas sur iOS et
CFNetwork n'y offre pas de mandataire SOCKS (phase 7a § 3) — les deux murs sont
toujours là, et c'est pour ça que la phrase de la carte nomme l'iPhone.

---

## 1. L'installeur pose Tailcat sur Linux

### Ce qui a été écrit

`infra/relais/install.sh`, en cinq morceaux :

1. **Le binaire, épinglé.** L'archive amont v0.4.0, sha256 relevé sur le
   `checksums.txt` de la release :

   | Cible | Archive | sha256 |
   |---|---|---|
   | linux amd64 | `tailcat_0.4.0_linux_amd64.tar.gz` | `8b819c43dfdf806b5663e23535aba557bb106075b0b5839df289af9bba70bec2` |
   | linux arm64 | `tailcat_0.4.0_linux_arm64.tar.gz` | `3b77322350f64d229d5b2119b159b863b4bcffa0a62a0294682423a19956dc76` |

   La somme est vérifiée **avant** de déplier : déplier une archive qu'on n'a
   pas vérifiée, c'est écrire sur le disque ce qu'on voulait refuser. Les
   binaires Linux viennent de l'amont comme Continuwuity et les ponts Linux ;
   c'est le binaire **macOS** qui entre dans notre publication et dans
   `SHA256SUMS` (livrable 2), parce que l'amont n'en publie pas.

2. **Une clé persistante**, dans le dossier du Relais et pas dans
   `~/.config/tailcat/keys/` — `--key` avec une barre oblique est un chemin :

   ```
   $PREFIX/tailcat/relais.private.json   0600
   ```

   Persistante, parce qu'un jeton qui changerait à chaque redémarrage périmerait
   tous les codes déjà émis. Dans le dossier du Relais, parce qu'un « tout
   retirer » doit l'emporter.

3. **Le service `correspondance-tailcat`**, devant le port du Relais et rien
   d'autre : `serve $PORT` n'ouvre que celui-là — pas de nœud de sortie, pas de
   SSH, pas de service de fichiers.

4. **Le jeton, relu au bon endroit.** C'est le point qui ne se devine pas :

   > `genkey` imprime un addrblob, mais **ce n'est pas celui que le serveur
   > publie**. Avec `--region auto`, la clé porte `RegionID = -1` et la région
   > DERP est choisie *au démarrage du serveur*. Lire la sortie de `genkey`
   > donnerait donc un jeton faux — et muet, ce qui est pire.

   La sortie du serveur porte le bon (`# 🐈 Server listening with saved key …`),
   mais un journal se lit mal et se lit tard. `tailcat` accepte
   `TAILCAT_ADDR_FILE` : il y écrit l'adresse publiée **à chaque démarrage**.
   L'installeur pose donc une enveloppe qui exporte la variable, et lit le
   fichier — une source, écrite par le seul qui sache.

   ```bash
   $ cat ~/unclic/tailcat/servir.sh
   #!/usr/bin/env bash
   export TAILCAT_ADDR_FILE="/home/meff/unclic/tailcat/adresse"
   exec "/home/meff/unclic/bin/tailcat" serve --key="/home/meff/unclic/tailcat/relais.private.json" 8010
   ```

5. **Le jeton dans le code d'appairage** — champ `tailcat`, facultatif, format
   déjà étendu en phase 7a — et dans la sortie `--json`.

### Le défaut qu'une seconde exécution a révélé

`systemctl --user enable --now` **ne redémarre pas** une unité déjà active. Sans
un `restart` explicite, la seconde exécution de l'installeur effaçait le fichier
d'adresse, attendait quarante secondes que personne ne le réécrive, et concluait
à tort « tailcat n'a pas publié d'adresse ». Corrigé, et éprouvé plus bas.

### Ce que Tailscale devient

Un repli, que l'installeur ne pose toujours pas. Le message qui disparaît :

```diff
- Tailscale absent. Cet installeur ne le pose PAS (ça demande sudo : …).
- Le code portera http://127.0.0.1:8010 — joignable depuis un autre poste
- par : ssh -N -L 8010:127.0.0.1:8010 <cette machine>.
+ Tailcat est posé : le code portera son jeton, et le Mac s'y connectera tout
+ seul, sans tunnel ssh et sans Tailscale. L'iPhone, lui, a encore besoin de
+ Tailscale (curl -fsSL https://tailscale.com/install.sh | sh, puis
+ sudo tailscale up) : il n'embarque pas Tailcat.
```

Si Tailscale est là, le code porte **les deux** : `homeserver` est l'adresse du
tailnet, `tailcat` le jeton. Une app qui ne connaît pas le champ retombe donc
sur l'adresse ; une app qui le connaît n'a besoin de rien d'autre. `--sans-tailcat`
rend le chemin d'avant, qui reste éprouvé par les tests de plan.

Sur macOS, **rien** : le Relais et l'app sont sur la même machine, et y poser
Tailcat serait un tunnel de `127.0.0.1` vers `127.0.0.1`.

### La preuve — installation sur le NUC depuis `~/unclic` vide

```
$ ssh nuc 'ls ~/unclic'
ls: impossible d'accéder à '/home/meff/unclic': Aucun fichier ou dossier de ce type

$ ssh nuc 'cd /tmp && time bash install.sh --prefix ~/unclic'
→ tailcat : sha256 8b819c43dfdf806b5663e23535aba557bb106075b0b5839df289af9bba70bec2 ✓ (v0.4.0)
…
→ service correspondance-relais démarré (journal /home/meff/unclic/logs/relais.log)
→ tailcat : clé tirée dans /home/meff/unclic/tailcat/relais.private.json (0600)
→ service correspondance-tailcat démarré (journal /home/meff/unclic/logs/tailcat.log)
→ attente du Relais sur http://127.0.0.1:8010
→ ✓ le Relais répond ({"name":"continuwuity","version":"26.8.1 (ab3c05d)"})
→ ✓ tailcat publie tco2FwWCAf1F… (106 octets)
→ ✓ @essai:unclic.local enregistré
…
✓ le Relais répond, connecté comme @essai:unclic.local (/login puis /account/whoami).
  Ponts : WhatsApp 29318, Signal 29328, Instagram 29330, Messenger 29331 — portails chiffrés.
  Tailcat est posé : le code portera son jeton, et le Mac s'y connectera tout seul, …

  correspondance://relais/eyJleHAiOjE3ODgzNTUzODguMDk0OTAxLCJob21lc2VydmVyIjoiaHR0cDovLzEyNy4w…

  Vérification (six mots) : usine marée dune chêne zeste encre
  Ce code porte un jeton Tailcat : le Mac joindra ce Relais sans tunnel ssh
  et sans Tailscale. Il porte aussi un mot de passe : ne le poste nulle part.

real	0m34,848s
```

Le code décodé porte bien le jeton :

```json
{"exp":1788355388.094901,"homeserver":"http://127.0.0.1:8010","password":"…",
 "server":"unclic.local",
 "tailcat":"tco2FwWCAf1F4PEB0p5EHmqkpzVB-r6R1MmDJlGtLcSGiv1lsjUGFrWCAGSUcEzQTK_0W8bEMtZbhMnId8oNSIJU0o9ueIkEqWF2FpGQEv",
 "user":"essai","v":1}
```

Et le mode `--json` le dit aussi, à l'étape et au code :

```json
{"etape": "tailcat", "etat": "debut", "detail": "le jeton que le code d'appairage portera"}
{"etape": "tailcat", "etat": "ok", "detail": "jeton de 106 caractères — le Mac se connectera sans tunnel ssh et sans Tailscale"}
{"etape": "appairage", "etat": "ok", "code": "correspondance://relais/…", "mots": ["usine","marée","dune","chêne","zeste","encre"], "tailcat": true}
```

### Rejouée, l'installation ne casse rien et rend le même jeton

```
→ tailcat déjà posé (v0.4.0)
→ tailcat : clé déjà là, conservée (le jeton des codes déjà émis reste valable)
→ service correspondance-tailcat démarré (journal /home/meff/unclic/logs/tailcat.log)
→ ✓ tailcat publie tco2FwWCAf1F… (106 octets)      ← le même
```

### La preuve depuis ce Mac — sans tunnel ssh, sans Tailscale

```
$ pgrep -fl "ssh -N"          → aucun
$ command -v tailscale        → absent
$ lsof -i :8010               → rien n'écoute

$ tailcat parse <jeton>
{ "ServerPublic": "nodekey:1fd45e0f…", "ServerDiscoPublic": "discokey:06494704…", "RegionID": 303 }

$ tailcat ping --timeout=15s <jeton>
pong in 134.07ms via DERP(fra)

$ tailcat socks --listen=127.0.0.1:11080 <jeton> &
2026/09/02 15:08:23 SOCKS running at socks5h://127.0.0.1:11080

$ curl -s --socks5-hostname 127.0.0.1:11080 http://server.tailcat:8010/_matrix/client/versions
{"versions":["r0.0.1",…,"v1.18"],"unstable_features":{…}}

$ curl -s --socks5-hostname 127.0.0.1:11080 http://server.tailcat:8010/_continuwuity/server_version
{"name":"continuwuity","version":"26.8.1 (ab3c05d)"}

$ curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8010/_matrix/client/versions
000                                            ← aucun autre chemin n'existe
```

### Rien ne déborde du dossier

```
$ ssh nuc 'ls -la ~/unclic/tailcat/; ls ~/.config/tailcat'
-rw-------  106  adresse
-rw-------  318  relais.private.json
-rwx------  443  servir.sh
ls: impossible d'accéder à '/home/meff/.config/tailcat': Aucun fichier ou dossier de ce type
```

### `uninstall.sh` emporte tout, des deux côtés

```
$ ssh nuc 'cd /tmp && bash uninstall.sh --prefix ~/unclic'
→ service correspondance-relais arrêté et désactivé
→ service correspondance-tailcat arrêté et désactivé
→ service correspondance-mautrix-whatsapp arrêté et désactivé
→ service correspondance-mautrix-signal arrêté et désactivé
→ service correspondance-mautrix-instagram arrêté et désactivé
→ service correspondance-mautrix-messenger arrêté et désactivé
→ /home/meff/unclic effacé
✓ le Relais est retiré de cette machine.

$ ssh nuc 'systemctl --user list-unit-files "correspondance-*"'
correspondance-agent.service   disabled       ← la prod, intacte
correspondance-cc.service      enabled
correspondance-claude.service  enabled
correspondance-hermes.service  enabled

$ ssh nuc 'pgrep -x tailcat; ls ~/.config/tailcat'
aucun processus tailcat
ls: impossible d'accéder à '/home/meff/.config/tailcat': Aucun fichier ou dossier de ce type
```

Et sur ce Mac, où rien n'a été posé cette fois, il **refuse** — c'est la garde
qui compte, parce que `~/.correspondance-unclic/` y porte la chaîne Linux et le
tailcat de la phase 7a :

```
$ bash infra/relais/uninstall.sh
!! /Users/…/.correspondance-unclic ne porte pas la marque .correspondance-relais — rien n'est effacé.
   (les services, eux, ont bien été retirés)
$ ls ~/.correspondance-unclic
crypto-linux    tailcat
```

### Le plan, les deux hôtes, et le repli

`infra/relais/tests/install-plan.sh` couvre désormais les deux hôtes Linux, le
Mac (où il ne doit **rien** y avoir), et le repli `--sans-tailcat` :

```
$ bash infra/relais/tests/install-plan.sh | tail -3
  ✓ une étape émise est bien du JSON
  ✓ un détail vide reste un champ
Plan d'installation du Relais : tout est conforme.
```

Ce qu'il éprouve de neuf, entre autres : l'archive épinglée et sa somme, la clé
persistante, le service devant le port du Relais, `TAILCAT_ADDR_FILE` plutôt que
`genkey`, le jeton dans le code, la phrase sur l'iPhone, le `restart` qui
manquait — et, en négatif, que le message « il faudrait sudo » a bien disparu,
que le Mac ne pose rien, et qu'un hôte arm64 ne prend pas l'archive amd64.

### Mesures

| | Valeur |
|---|---|
| installation complète, NUC, dossier vide | **34,8 s** (quatre ponts compris) |
| binaire tailcat linux amd64 | 18 088 096 o |
| RSS du service `correspondance-tailcat` | **25,3 Mio** |
| dossier `~/unclic` complet | 344 Mio |
| jeton dans le code d'appairage | 106 caractères |
| aller-retour DERP(fra), premier ping | 134 ms (44 ms en médiane sur `/sync`, mesuré en 7a) |

---

## 2. Le mandataire dans l'app, prêt à livrer

### Le choix : embarqué, pas téléchargé — et pourquoi

Un binaire **téléchargé** à l'exécution arriverait non signé, hors du sceau de
l'app — c'est-à-dire hors de la notarisation — et à la merci de qui tient le
réseau au moment précis où l'on ouvre un chemin réseau ; il faudrait en plus
gérer la quarantaine, le hors-ligne et une somme de plus.
**Embarqué**, il est signé avec l'app, il marche sans réseau, et « ce que l'app
lance » est exactement « ce qui a été notarisé ».

### Le binaire macOS

L'amont ne publie **aucun** binaire macOS (v0.4.0 : Linux et Windows ; macOS
passe par un tap Homebrew, que le spike s'interdit dans la pile livrée). Il est
donc construit par `infra/relais/construire.sh --quoi tailcat`, au même tag :

```
$ bash infra/relais/construire.sh --quoi tailcat
→ tailcat : sources déjà là (v0.4.0)
→ tailcat-darwin-arm64 : 0m09s, 39d4418bfad02746cc49052c5b933a2dffeaecaf811a6f445572b9ea6e152b47
→ SHA256SUMS régénéré :
     …
     39d4418bfad02746cc49052c5b933a2dffeaecaf811a6f445572b9ea6e152b47  tailcat-darwin-arm64
```

`GOFLAGS=-trimpath` pour qu'un binaire publié ne dise pas où vit le dossier
personnel de qui l'a construit, et `CGO_ENABLED=0` — tailcat n'a pas de
dépendance C, contrairement aux ponts. 29 273 490 o, 9 s.

### La phase de build

`project.yml`, cible macOS, `postCompileScripts` → « Embed tailcat » : elle
**copie**, elle ne construit pas, depuis `~/unclic-publication`. Deux choses
s'y décident.

- **Elle signe séparément.** La signature de l'app ne fait que *sceller* un
  exécutable imbriqué ; elle ne le signe pas. Sans ce `codesign`, une build
  notarisée porterait un binaire « not signed at all » et Gatekeeper refuserait
  **l'app entière**, pas seulement le mandataire.
- **Elle n'échoue pas si le binaire manque** : une build de développement doit
  rester possible sur une machine qui n'a pas fait tourner `construire.sh`. Elle
  émet un `warning:` et retire un éventuel tailcat périmé du bundle ; l'écran,
  lui, dit la vérité (plus bas).

```
$ CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj \
    -scheme Correspondance -configuration Debug -derivedDataPath /tmp/dd-unclic build
Embedded tailcat: /Users/…/unclic-publication/tailcat-darwin-arm64 →
  /tmp/dd-unclic/Build/Products/Debug/Correspondance.app/Contents/Helpers/tailcat
** BUILD SUCCEEDED **

$ codesign -dv --verbose=2 …/Correspondance.app/Contents/Helpers/tailcat
Identifier=tailcat
Format=Mach-O thin (arm64)
CodeDirectory v=20500 size=56403 flags=0x10000(runtime) …
Authority=Apple Development: … (8R262567K3)

$ codesign --verify --deep --strict …/Correspondance.app   → valide
$ …/Correspondance.app/Contents/Helpers/tailcat version    → v0.4.0
```

Une chose s'est perdue en chemin et a été rattrapée : **`xcodegen` réengendre
l'`Info.plist`.** L'exception ATS de `server.tailcat`, écrite à la main en phase
7a, a disparu à la première régénération. Elle vit maintenant dans `project.yml`,
avec sa raison — ce HTTP entre dans un tunnel WireGuard avant le premier octet
sur le réseau.

### Où l'app cherche tailcat

`CORRESPONDANCE_TAILCAT` (une preuve, un essai) → `Contents/Helpers/tailcat` →
`Contents/Resources/tailcat` → les chemins de développement → Homebrew. Le
bundle avant Homebrew, parce qu'un tailcat de Homebrew n'est ni signé avec
l'app, ni notarisé avec elle, ni forcément à la version que nous avons éprouvée.

Absent, le message dit **où** il manque :

> tailcat n'est pas dans ce bundle — le Relais se joindra par son adresse
> ordinaire. (bash infra/relais/construire.sh --quoi tailcat, puis reconstruire l'app)

### Il vit avec la session, et il renaît s'il tombe

- **Il démarre** quand le code d'appairage porte un jeton — et **avant** le
  `/login`, comme en 7a : posé après, le mot de passe serait déjà parti par le
  chemin qu'on voulait éviter.
- **Il s'arrête** avec « Déconnecter » (`disconnectMatrix`) et à la fermeture de
  l'app (`NSApplication.willTerminateNotification`, observée dans `InboxStore` —
  le délégué n'a pas de chemin vers ce magasin, et en faire descendre un pour un
  seul `terminate()` coûterait plus que ça ne rapporte).
- **Il renaît** comme `cc` : `terminationHandler`, délai qui double de 1 s à
  30 s, abandon dit au bout de huit chutes.

Le piège de la relance, qui n'est pas dans le processus mais **autour** :

> `--listen=127.0.0.1:0` fait choisir le port par le système, donc **le port
> change à chaque naissance**. Relancer le processus sans rien d'autre laisserait
> l'app parler à un port fermé, en croyant le Relais muet. D'où le rappel
> `auRedemarrage`, qui re-pose le mandataire sur le client Matrix — la
> configuration d'une `URLSession` étant figée à sa création, cela signifie en
> refaire une.

### Deux copies qui avaient divergé

L'écran d'accueil appairait **sans** Tailcat : la carte « Sur une machine à moi »
lisait le code, ignorait le champ `tailcat`, et se connectait à l'adresse. Le
défaut ne se voyait pas — il donnait juste « le homeserver ne répond pas » sur un
Relais parfaitement vivant. La suite « chemin d'abord, session ensuite » vit
maintenant une seule fois, dans `InboxStore.connecterParLeCode`, et les deux
écrans l'appellent.

### La feuille dit par où ça passe

`CheminDuRelais`, calculé sur le code seul — aucun réseau, aucun processus :

| Ce que porte le code | Chemin | Ce que l'écran ajoute |
|---|---|---|
| un jeton `tailcat` | **via Tailcat** | « …sans tunnel ssh et sans Tailscale. L'iPhone, lui, a encore besoin de Tailscale. » |
| `100.64.0.0/10` ou `*.ts.net` | **via Tailscale** | « il faut Tailscale sur cette machine, et sur l'iPhone » |
| `127.0.0.1`, `localhost` | sur cette machine | « rien à traverser » |
| le reste | par son adresse | « elle ne vaut que depuis un réseau qui la joint » |

Les deux bornes du `100.64.0.0/10` sont vérifiées : `100.200.1.1` est une adresse
publique ordinaire, et la ranger dans un tailnet ferait dire à l'écran une chose
fausse.

### Les tests de vue-modèle

`CheminDuRelaisTests` (7) et `TailcatProxyBinaireTests` (7) : le jeton décide de
tout même quand l'adresse est celle d'un tailnet ; un champ présent mais **vide**
n'est pas un jeton ; les deux bornes du CGNAT ; le bundle avant Homebrew ; le
tilde développé ; l'absence qui parle du bundle ; la montée du délai de relance.

### La preuve d'intégration — sans piloter l'écran

`PreuveTailcatTests` prend le code d'appairage du NUC, démarre `TailcatProxy`,
fait `/versions` puis `/login` **par le mandataire**, referme la session ouverte,
et coupe. Elle est ignorée par défaut (une machine distante et un jeton de quinze
minutes n'ont rien à faire dans la suite ordinaire ; la faire échouer par défaut
apprendrait à ignorer le rouge) et se déclenche par l'environnement :

```bash
cd Packages/CorrespondanceCore
CORRESPONDANCE_PREUVE_TAILCAT='correspondance://relais/…' \
CORRESPONDANCE_TAILCAT=/tmp/dd-unclic/Build/Products/Debug/Correspondance.app/Contents/Helpers/tailcat \
  swift test --scratch-path /tmp/build-unclic-sanscrypto --filter PreuveTailcatTests
```

```
Test Case '-[…PreuveTailcatTests testUnCodeDAppairageSuffitAJoindreLeRelais]' passed (0.364 seconds).
→ mandataire SOCKS sur 127.0.0.1:62657
→ /versions par le mandataire : 22 versions, jusqu'à v1.18
→ /login par le mandataire : connecté comme @essai:unclic.local
→ session de preuve refermée
→ mandataire arrêté, aucun processus laissé
```

C'est **le binaire du bundle** qui a servi, et c'est le code de l'app — le
processus enfant, la lecture du port dans sa sortie, le dictionnaire SOCKS de
CFNetwork — qui a joint le Relais, pas un outil en ligne de commande à côté.

### Ce qui reste au vérificateur, écran allumé

Trois vérifications visuelles, que l'agent n'a pas faites (le propriétaire
travaille sur ce Mac) :

1. **La feuille du code d'appairage.** Réglages › Serveur Matrix, coller un code
   du NUC **sans se connecter** : sous les six mots doivent apparaître
   « Chemin : via Tailcat » et la phrase sur l'iPhone. Puis « Connecter » :
   l'inbox arrive, et la ligne d'état dit « Relais joint via Tailcat (mandataire
   local ****) ».
2. **Le repli sans binaire.** Renommer `Contents/Helpers/tailcat`, relancer,
   coller le même code : l'écran doit dire « tailcat n'est pas dans ce bundle »
   et **tenter l'adresse du code** — pas échouer.
3. **La carte « Sur une machine à moi »**, sur l'écran d'accueil sans Relais : la
   phrase doit être « Allumée en permanence, tout marche partout. Le Mac s'y
   connecte tout seul ; l'iPhone a encore besoin de Tailscale. »

La commande pour l'app :

```bash
CORRESPONDANCE_HOME=unclic /tmp/dd-unclic/Build/Products/Debug/Correspondance.app/Contents/MacOS/Correspondance
```

---

## 3. La carte et les textes

- **`AccueilRelaisView`** : « Allumée en permanence, tout marche partout. Le Mac
  s'y connecte tout seul ; l'iPhone a encore besoin de Tailscale. » (La ligne
  d'avant disait « Il faut Tailscale sur l'iPhone », qui se lisait comme « il
  faut Tailscale », point.)
- **`docs/MATRIX-SETUP.md`** : un tableau « Par où le Mac joint le Relais » qui
  sépare la prod (Tailscale) du Relais un clic (Tailcat), et dit ce qui ne change
  pas — l'iPhone, et le fait qu'un homeserver n'écoute que sur `127.0.0.1` dans
  les deux cas.
- **`docs/PLAN-relais-un-clic.md`** : la marche n° 2 devient explicitement
  « l'iPhone seulement » ; l'installeur ne pose plus « Docker et Tailscale » mais
  Tailcat ; la phrase de l'écran d'accueil est celle de la carte ; la réserve R2
  précise que Tailscale reste manuel *sur l'iPhone*.
- **`docs/spike-un-clic/CONCLUSION.md`** : le titre du § Tailcat devient
  « essayé (7a), **par défaut** (7b) » ; la commande telle qu'un utilisateur la
  verra dit le jeton ; le point 7 de « ce qui reste » est barré, et ce qui reste
  vraiment est la tranche iPhone.

Ce qui n'a pas été dit à la légère : **qui détient le jeton joint le Relais.**
C'est le même régime que le mot de passe que le code porte déjà — donc pas une
régression — mais un code d'appairage est désormais une clé de réseau en plus
d'être une clé de compte. Il périme toujours en quinze minutes, et un « tout
retirer » emporte la clé, donc tous les jetons émis.

---

## Rejouer

```bash
cd ~/correspondance-un-clic

# 1. L'installeur, sur le NUC
scp infra/relais/install.sh infra/relais/uninstall.sh nuc:/tmp/
ssh nuc 'cd /tmp && bash install.sh --prefix ~/unclic'          # ~35 s, finit sur le code
bash infra/relais/tests/install-plan.sh                          # le plan des trois hôtes

# La preuve depuis ce Mac, sans tunnel ni Tailscale
JETON=<le champ tailcat du code>
~/.correspondance-unclic/tailcat socks --listen=127.0.0.1:11080 "$JETON" &
curl -s --socks5-hostname 127.0.0.1:11080 http://server.tailcat:8010/_matrix/client/versions

# 2. Le binaire macOS, puis l'app
bash infra/relais/construire.sh --quoi tailcat                   # ~10 s
CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Debug -derivedDataPath /tmp/dd-unclic build
codesign --verify --deep --strict /tmp/dd-unclic/Build/Products/Debug/Correspondance.app

# La preuve d'intégration (le code d'appairage doit être frais : 15 minutes)
cd Packages/CorrespondanceCore
CORRESPONDANCE_PREUVE_TAILCAT='correspondance://relais/…' \
CORRESPONDANCE_TAILCAT=/tmp/dd-unclic/Build/Products/Debug/Correspondance.app/Contents/Helpers/tailcat \
  swift test --scratch-path /tmp/build-unclic-sanscrypto --filter PreuveTailcatTests

# Les tests, dans les deux configurations. Scratch séparés — obligatoire.
rm -rf .build && swift test --scratch-path /tmp/build-unclic-sanscrypto              # 838, 1 ignoré
rm -rf .build && CORRESPONDANCE_CRYPTO=1 swift test --scratch-path /tmp/build-unclic-crypto  # 843, 1 ignoré
cd ../.. && CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj \
  -scheme "Correspondance iOS" -configuration Debug -derivedDataPath /tmp/dd-unclic \
  -destination 'generic/platform=iOS Simulator' build

# Ne rien laisser
ssh nuc 'cd /tmp && bash uninstall.sh --prefix ~/unclic; rm -f /tmp/install.sh /tmp/uninstall.sh'
# Sur ce Mac, rien n'a été posé : uninstall.sh refuse, et c'est ce qu'on veut —
# ~/.correspondance-unclic/ porte la chaîne Linux et le tailcat de la phase 7a.
```

---

## Ce qui reste

1. **L'iPhone par Tailcat** : `gomobile bind` (le runtime Go dans le bundle, 10 à
   15 Mio par tranche) et une façon de composer sans SOCKS — un `URLProtocol`,
   ou une socket locale. Le coût est à chiffrer avant de s'engager, pas à
   supposer.
2. **La publication**, toujours pas faite : `publier.sh --dry-run` liste
   désormais `tailcat-darwin-arm64` avec le reste. C'est une décision du
   propriétaire.
3. **La branche « Tailscale présent »** de l'installeur Linux n'est toujours pas
   éprouvée en vrai : le NUC n'a pas Tailscale en natif. Le plan la couvre, la
   pose non.
4. **Une capture de la feuille d'appairage** montrant « via Tailcat » — les trois
   vérifications visuelles ci-dessus.
5. Ce que la phase 7a laissait, et qui n'a pas bougé : `deploy.sh` encore en
   Docker sur le NUC, `cc` Linux arm64, l'App Group `group.com.correspondance`.

## État des deux machines à la fin

- **Ce Mac** : `~/unclic-publication/` porte un fichier de plus,
  `tailcat-darwin-arm64` (29,3 Mio), et son `SHA256SUMS` régénéré ;
  `~/.correspondance-unclic-src/tailcat` porte les sources au tag v0.4.0 ;
  `~/.correspondance-unclic/` est inchangé depuis la phase 7a. **Aucun Relais
  n'a été posé sur ce Mac** pendant cette phase, aucun processus tailcat ne
  survit (`pgrep -fl tailcat` → rien), aucun tunnel ssh n'a été ouvert.
- **Le NUC** : **rien**. `uninstall.sh` a été rejoué à la fin (sortie ci-dessus) :
  `~/unclic` n'existe plus, les six unités de spike ont disparu, aucun processus
  `tailcat` ne tourne, et `~/.config/tailcat` n'a jamais existé. Les scripts
  déposés dans `/tmp` ont été retirés. La production n'a jamais été touchée :
  `correspondance-cc`, `-claude` et `-hermes` sont restés `active` du début à la
  fin — et **aucune unité de spike ne lance d'agent cette fois**, donc rien qui
  puisse rejouer l'incident de la phase 7a. Le vérificateur repose la pile en une
  commande (§ Rejouer) ; il lui faut de toute façon un code d'appairage frais,
  qui périme en quinze minutes.

---

## Vérification (2 sept. 2026, vérificateur)

Rejoué : 838 tests (1 ignoré, la preuve distante), `install-plan.sh` conforme ; NUC posé
depuis `~/unclic` vide en 34 s par `--json`, le code porte un jeton de 106 caractères, l'unité
`correspondance-tailcat` active ; depuis ce Mac, `tailcat socks <jeton>` puis
`curl --socks5-hostname … http://server.tailcat:8010/_continuwuity/server_version` rend
Continuwuity 26.8.1, et le chemin direct rend `000`. Retrait complet du NUC, prod active,
aucun tailcat ni orphelin des deux côtés. Le bundle Debug embarque `Contents/Helpers/tailcat`
(28,8 Mio) et `codesign --verify --deep --strict` passe. **Un piège relevé** : un DerivedData
résolu une fois avec `CORRESPONDANCE_CRYPTO=1` ne construit plus sans le drapeau (modules FFI
introuvables) — soit on garde le drapeau partout, soit on change de DerivedData ; à écrire dans
`MATRIX-SETUP.md` au moment de la fusion. Phase acceptée ; les trois vérifications visuelles
restent à faire par le propriétaire.
