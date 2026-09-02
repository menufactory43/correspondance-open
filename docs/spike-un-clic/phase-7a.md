# Phase 7a — `cc` chiffré sous Linux, les deux écrans, et Tailcat

2 septembre 2026. Trois livrables, chacun commis avec ses preuves. Rien ici n'est
une lecture : tout a tourné sur ce Mac et sur le NUC, sous des dossiers à part,
sans toucher la production.

| Livrable | Verdict |
|---|---|
| 1. `cc` chiffré sous Linux | **fait**, et éprouvé sur le NUC — `@cc ping` chiffré → `pong` en `m.room.encrypted` |
| 2. Les deux écrans | **faits** sur Mac et iPhone, cinq captures, la déconnexion menée jusqu'au bout |
| 3. Spike Tailcat | **fait** — l'app joint le Relais du NUC sans tunnel ssh et sans Tailscale ; deux murs nommés pour l'iPhone |

Tests : **823** sans la crypto, **828** avec. Les deux cibles Xcode compilent.

---

## 1. `cc` chiffré sous Linux

### La question préalable : comment `cc` est-il compilé pour Linux aujourd'hui ?

Il fallait la trancher avant tout le reste, et la réponse a décidé du travail.

`infra/agent/deploy.sh` **compile sur le NUC, dans un conteneur Docker** :

```bash
SWIFT_IMAGE="${SWIFT_IMAGE:-swift:6.1-bookworm}"
rsync -a … "$HERE/Packages/CorrespondanceCore/" "$SSH_HOST:~/${REMOTE_SRC}/"
ssh "$SSH_HOST" … docker run --rm -v "$PWD":/src … "$SWIFT_IMAGE" \
  swift build --product correspondance-agent -c release --static-swift-stdlib
```

C'est-à-dire : sur la machine de production, avec Docker, avec Swift 6.1 — les
trois choses que le spike s'interdit. `infra/agent/install.sh`, lui, ne compile
rien : il **télécharge** un binaire déjà construit depuis `correspondance-releases`.
Il fallait donc, avant toute crypto, une chaîne de compilation croisée sur ce Mac.

**Elle n'existait pas** : `swift sdk list` rendait « No Swift SDKs are currently
installed ». Elle a été posée, et c'est noté ici parce que c'est une dépendance
nouvelle de la machine de construction.

### La chaîne, posée

```bash
rustup target add x86_64-unknown-linux-musl
brew install zig                       # 0.16.0

# La chaîne Swift open source. Celle d'Xcode ne sert PAS.
curl -fLO https://download.swift.org/swift-6.3.3-release/xcode/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE-osx.pkg
installer -pkg swift-6.3.3-RELEASE-osx.pkg -target CurrentUserHomeDirectory   # sans sudo

# Le SDK Linux statique, à la version EXACTE de la chaîne ci-dessus.
swift sdk install \
  https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
  --checksum 87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b
```

**Pourquoi la chaîne d'Xcode ne sert pas.** Elle s'appelle pourtant « Apple Swift
version 6.3.3 ». Premier essai, avec elle :

```
error: compiled module was created by an older version of the compiler;
rebuild 'Foundation' and try again:
  …/swift-linux-musl/musl-1.2.5.sdk/x86_64/usr/lib/swift_static/linux-static/Foundation.swiftmodule/…
```

Le `swiftlang-6.3.3.1.3` d'Apple et le `6.3.3-RELEASE` d'open source ne partagent
pas le format de module. Un SDK Swift veut la chaîne open source de sa version,
exactement. Le message accuse `Foundation` d'être vieux, ce qui est le contraire
du problème.

**Deux détails du SDK.** L'adresse du bundle n'est pas celle que le nommage des
versions précédentes laisse deviner : la version d'artefact est `0.1.0` pour
Swift 6.3.x (elle était `0.0.1` jusqu'à 6.2), et `…_static-linux-0.0.1…` rend un
302 vers une page 404. `https://www.swift.org/api/v1/install/releases.json` porte
la bonne version **et** la somme. Et le SDK est en **musl** (1.2.5) : c'est ce qui
oblige la bibliothèque Rust à l'être aussi.

### La bibliothèque Rust — `infra/relais/crypto-linux.sh`

```bash
cargo rustc -p matrix-sdk-crypto-ffi --lib --release \
  --target x86_64-unknown-linux-musl --crate-type staticlib
```

Trois choses que la phase 5 n'avait pas pu prévoir depuis la lecture des sources :

1. **On ne construit que le `staticlib`.** Le crate déclare
   `crate-type = ["cdylib", "staticlib"]` ; le `cdylib` réclamerait un éditeur de
   liens Linux complet, le `.a` ne réclame que le compilateur. `cargo rustc
   --crate-type staticlib` le dit — mais il faut aussi `--lib`, sinon cargo
   refuse (« the package … passing, e.g., `--lib` ») parce que le crate porte
   également un `[[bin]]`.
2. **La caisse `cc` de Rust sabote zig.** Elle ajoute d'elle-même
   `--target=x86_64-unknown-linux-musl` — la triplette **Rust** — au compilateur C,
   et zig 0.16 répond :
   ```
   error: unable to parse target query 'x86_64-unknown-linux-musl': UnknownOperatingSystem
   ```
   L'enveloppe `zcc-musl` retire toute option `--target` reçue et impose
   `-target x86_64-linux-musl`. Sans ça, `blake3` (et tout ce qui a du C) échoue.
3. **musl, pas glibc**, parce que le SDK Swift statique est en musl : les deux
   moitiés du binaire final doivent parler la même libc. Ce qui en sort est
   **statique**, donc tourne partout — le NUC est en glibc 2.36 et ne s'en aperçoit pas.

Sortie :

```
    Finished `release` profile [optimized] target(s) in 2m 06s
real 126.87  user 470.28  sys 32.82
-rw-r--r--  166 380 118  libmatrix_sdk_crypto_ffi.a
0fe200961ee422a72b7c4c651aa2bc6ccd2beaca235aee78c3006fb8d601e087
```

La somme n'est pas épinglée dans le dépôt, délibérément : `cargo` n'est pas
reproductible au bit près d'une machine à l'autre (mêmes raisons qu'en phase 6
pour Continuwuity). On la relève à chaque construction.

### L'empaquetage SwiftPM

Les en-têtes uniffi entrent dans le dépôt
(`Sources/MatrixSDKCryptoFFILinux/include/`) — c'est du texte, figé par la
version épinglée, et un `.a` sans eux ne sert à rien. La `.a` de 166 Mio, non.

La carte de modules est celle de l'XCFramework **moins ses trois `use "Darwin"`** :
ce module n'existe pas sous Linux, et clang refuse la carte entière pour cette
seule ligne. Les liaisons Swift engendrées sont **inchangées** — elles font
`#if canImport(matrix_sdk_cryptoFFI)`, et un `module.modulemap` qui déclare les
trois modules dans un seul fichier suffit.

`Package.swift` porte les deux mondes derrière `CORRESPONDANCE_CRYPTO_LINUX` :

```bash
CORRESPONDANCE_CRYPTO=1 \
CORRESPONDANCE_CRYPTO_LINUX=~/.correspondance-unclic/crypto-linux/x86_64 \
  ~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift build \
  --product correspondance-agent -c release --swift-sdk x86_64-swift-linux-musl \
  --scratch-path /tmp/build-unclic-linux-crypto
```

**Trois pièges du manifeste, chacun muet.**

- Le vérificateur de types abandonne sur le littéral des cibles dès qu'on y
  ajoute une concaténation conditionnelle de plus : *« the compiler is unable to
  type-check this expression in reasonable time »*, sur la ligne du `Package(`,
  ce qui ne dit rien de la cible fautive. Il faut sortir le tableau et le typer.
- Un `let` déclaré **après** `let package = Package(...)` est lu avant d'être
  initialisé : le manifeste se compile, ne produit aucun JSON, et SwiftPM dit
  seulement *« Missing or empty JSON output »*. Une `var` calculée règle tout.
- **`CryptoKit` n'existe pas sous Linux.** Le coffre qui porte les clés de
  signature l'utilise (AES-GCM, HKDF). swift-crypto 3.15.1 le remplace : *la même
  implémentation BoringSSL derrière la même API*, donc un coffre scellé sur le Mac
  s'ouvre sur le Linux — ce qui est tout l'enjeu. La dépendance n'entre que pour
  la construction Linux ; sur Apple, CryptoKit est dans le système.

### Les binaires

| | sans crypto | avec crypto |
|---|---|---|
| `correspondance-agent` Linux x86-64, non dépouillé | **170,7 Mio** | **224,3 Mio** |
| déposé sur le NUC, `strip` | — | **87,7 Mio** |
| durée de la construction croisée (à chaud) | 23,5 s | 48,6 s |

`sha256 c0def6ecfbff49741b674cd7de91f8a96c8eba6bbd6b89b5027969b8cfc423c0`
(`file` : *ELF 64-bit LSB executable, x86-64, statically linked, stripped*).
RSS mesuré sur le NUC après 35 min : **39,7 Mio**.

Le `strip` se fait sur le NUC : ni `llvm-strip` ni `zig objcopy --strip-all`
(« error: unimplemented ») ne savent dépouiller un ELF depuis ce Mac.

### La preuve — `infra/relais-spike/preuve-cc-linux.sh`

Relais du spike posé sur le NUC par `install.sh --prefix ~/unclic`, `cc` croisé
depuis ce Mac, l'appareil A sur le Mac. Extraits :

```
### 5. cc démarre SUR LE NUC — avec la machine crypto
14:04:08 binaire : /home/meff/unclic/bin/correspondance-agent (compilé le 2 sept. 13:58)
14:04:08 chiffrement : compilé
14:04:08 chiffrement branché — appareil …, ed25519 … · magasin /home/meff/unclic/cc/crypto/…
14:04:08 à l'écoute de « @cc » pour @essai:unclic.local — plafond 30/h

### 7. ce que cc en fait
14:04:17 [!u3T8iw…] @essai:unclic.local → « ping »
14:04:20 [!u3T8iw…] ← 4 caractères

### 8. la réponse de cc, relue EN CLAIR par l'appareil A (ce Mac)
  ✓ @essai:unclic.local : « @cc ping »
  ✓ @cc:unclic.local : « pong »

### 9. ce que le Relais du NUC stocke — vu par HTTP, sans le client
  $3xJ5Gj…  type=m.room.encrypted  algorithm=m.megolm.v1.aes-sha2
    ciphertext (100 premiers) : AwgCEuABRFkb1IJzARS7/R/XHbwIHl67pTUswVfT9FOp6HvJ…
```

### L'erreur qui a servi de garde

Le premier essai a échoué, et bien :

```
14:00:51 chiffrement branché — … · magasin /home/meff/.correspondance-agent/crypto/…
14:00:52 démarrage refusé : un autre agent tourne déjà sur cette machine (pid 2873014).
14:00:52 arrêt définitif : un autre agent tourne déjà sur ce compte — deux agents répondraient deux fois.
```

L'unité passait `--agent cc` **et** `CORRESPONDANCE_AGENT_HOME`. Or
`AgentHome.resolve` donne la priorité à `--agent` — c'est écrit, et c'est juste
pour un plist statique, qui ne peut pas porter de variable. Résultat : `cc` a lu
`~/.correspondance-agent/config.json`, **l'amorce de la production**, s'est
connecté au vrai Relais, y a vu le status du vrai `cc` (pid 2873014, bien vivant)
et a refusé de démarrer. **La garde du second agent a fait exactement son
travail**, et c'est elle qui a révélé l'erreur.

Le seul reste était un dossier `crypto/` posé dans le dossier de production ; il
a été retiré, et les trois agents de prod (`cc`, `hermes`, `claude`) sont restés
`active` du début à la fin. L'unité du spike n'utilise plus que la variable —
`resolve` relit alors le nom du dossier (`unclic/cc` → « cc »), donc le
déclencheur reste `@cc`.

---

## 2. Les deux écrans

### Ce qui était difficile n'était pas la cryptographie

Le noyau de la phase 5 servait déjà tout. Ce qui manquait était une décision :
**quoi montrer à la première connexion d'un appareil ?** Elle ne se lit dans
aucun fait pris seul — c'est la rencontre de ce que le Relais héberge
(`GET /room_keys/version`) et de ce que **cette machine-ci** connaît :

| Relais | cet appareil | écran |
|---|---|---|
| aucune sauvegarde | — | « Note ta phrase de récupération » + *Créer la phrase* |
| version *N* | ne la connaît pas | « Entre ta phrase » — appareil neuf |
| version *N* | la connaît | « Sauvegarde *N* en place » + *Revoir* / *Changer la phrase* |
| — | pas de machine crypto | on le dit, on ne se tait pas |

`ModeleChiffrement` (dans `CorrespondanceCore`) porte ces états, éprouvé sans
Relais par un faux qui note ce qu'on lui a demandé. **Dix-neuf tests**, dont
celui qui tient la garde qui compte :

```swift
func testUnRafraichissementNeFaitPasDisparaitreLaPhraseNonNotee() async {
  // `sonder()` est appelé à chaque apparition de l'écran, et il aurait effacé
  // douze mots que personne n'avait recopiés — en laissant, sur le Relais,
  // une sauvegarde à jamais fermée.
}
```

### Trois choix qui se disent à l'écran

- **La sauvegarde ne naît qu'à « je l'ai notée »**, jamais avant. Créée d'abord,
  elle serait une sauvegarde que personne ne peut rouvrir.
- **La phrase est gardée au Trousseau de cette machine**, sinon « Revoir » serait
  un bouton qui ment. Le pied de la carte le dit, parce que c'est un compromis
  (qui ouvre ce Mac déverrouillé la lit) et pas une évidence.
- **Le mot de passe ne part que si le Relais le réclame.** « Déconnecter » tente
  d'abord sans rien, lit la `session` du 401 dans `dernierCorpsDErreur`, et
  n'affiche le champ qu'ensuite.

### La liste des appareils recolle deux moitiés qui ne se recouvrent pas

Le serveur (`GET /_matrix/client/v3/devices`) sait le nom et la dernière
activité ; la machine crypto sait si l'appareil est vérifié. D'où un troisième
état, **« état inconnu »**, qui n'est pas « non vérifié » : la machine n'a rien à
dire de cet appareil, et l'écran n'a pas à prétendre l'avoir jugé.

Et « dernière activité » vient du Relais, **qui ne l'écrit qu'une fois par
dizaine de minutes** — le même fait qui commande la fenêtre de quinze minutes de
la garde du second `cc` (commit `60c600a`). Le pied de la carte le dit, sinon un
appareil bien vivant paraîtrait dormir.

### La preuve, écran allumé

Cinq captures, contre le Relais du spike posé sur le NUC :

| Capture | Ce qu'elle montre |
|---|---|
| `phase-7a-phrase-a-proposer.png` | « Note ta phrase de récupération » + *Créer la phrase*, aucune sauvegarde |
| `phase-7a-phrase-a-noter.png` | les **douze mots numérotés**, la case « Je l'ai notée », *Continuer* éteint |
| `phase-7a-phrase-en-place.png` | « Sauvegarde 1085 en place · La phrase est gardée sur cet appareil » |
| `phase-7a-appareils.png` | quatre appareils, leur état et leur dernière activité |
| `phase-7a-deconnexion.png` | « Le Relais demande le mot de passe du compte pour déconnecter JAeO7hGS4a » |
| `phase-7a-appareil-deconnecte.png` | « JAeO7hGS4a est déconnecté », la ligne a disparu |

Vérifié sans le client : le jeton de l'appareil déconnecté répond désormais
`{"errcode":"M_UNKNOWN_TOKEN"}`.

Une chose ne s'est vue qu'à l'exécution : la machine crypto ne se branche qu'au
**premier `/sync` qui suit la connexion**, donc l'écran sondé juste après
l'appairage répond « compilé, pas encore connecté ». « Re-sonder » resonde
désormais les deux, sinon l'écran reste en arrière d'un tour.

### iOS

Les mêmes états, en `Section` de `List`, avec la liste des appareils derrière une
`NavigationLink` — quatre sessions au milieu des réglages noieraient le reste sur
un écran de six pouces. Le clavier est coupé de sa majuscule et de sa correction
sur le champ de la phrase, et la normalisation du modèle rattrape le reste.

**Pas de capture iOS.** La cible construit, mais l'écran ne s'ouvre qu'une session
liée, et lier un simulateur au Relais du spike demandait un appairage de plus pour
une capture. C'est dit plutôt que joint.

---

## 3. Spike Tailcat

### Le problème

Un Relais posé sur une machine à soi n'écoute que sur `127.0.0.1` — c'est ce
qu'il faut : un homeserver ouvert sur l'Internet est une porte. Le joindre depuis
un autre poste demandait soit **Tailscale** (un compte, un tailnet, une extension
système sur le Mac, rien du tout sur un iPhone qui ne l'a pas), soit **`ssh -N -L`**
(un terminal, une clé, une commande que personne ne retape).

Tailcat prend le plan de données de Tailscale — WireGuard, traversée de NAT,
relais DERP en repli — **sans son plan de contrôle** : ni compte, ni tailnet, ni
démon privilégié.

### Sur le NUC

```bash
cd ~/unclic/tailcat
curl -fsSLO https://github.com/tailscale/tailcat/releases/download/v0.4.0/tailcat_0.4.0_linux_amd64.tar.gz
sha256sum tailcat_0.4.0_linux_amd64.tar.gz
# 8b819c43dfdf806b5663e23535aba557bb106075b0b5839df289af9bba70bec2   ← conforme à checksums.txt
tar xzf tailcat_0.4.0_linux_amd64.tar.gz          # binaire : 18 088 096 o
./tailcat genkey --key=relais
# tco2FwWCDMWMaSLhgzXYPSUARziKjgONO6HWaaDZqpqsKA06ImH2FrWCCy3iGz0H0HYU9Vo7s8VthFRt0kKq0CCAw0_zwgzseMFGFpIA
```

Service `systemd --user` à côté des autres du spike :

```
ExecStart=%h/unclic/tailcat/tailcat serve --key=relais 8010
```

```
Active: active (running)   Memory: 8.9M
tailcat[…]: # Selected bootstrap relay region 303, Frankfurt
tailcat[…]: # 🐈 Server listening with saved key "relais": tco2FwWCDMW…
```

### Sur ce Mac — et le premier constat

**Aucun binaire macOS n'est publié.** La release v0.4.0 porte Linux
(amd64/arm64/armv7, `.tar.gz`/`.deb`/`.rpm`) et Windows ; macOS passe par le tap
Homebrew. Le spike interdisant Homebrew dans la pile livrée, il est construit
depuis le tag :

```bash
git clone --depth 1 --branch v0.4.0 https://github.com/tailscale/tailcat.git
GOFLAGS=-trimpath go build -o ~/.correspondance-unclic/tailcat ./cmd/tailcat   # 37,6 s → 29 273 490 o
```

C'est une dette : publier un binaire macOS demandera de le construire nous-mêmes
et de le signer, comme les quatre ponts de la phase 6.

### Le chemin, mesuré

```
$ tailcat parse <jeton>
{ "ServerPublic": "nodekey:cc58c69…", "ServerDiscoPublic": "discokey:b2de21b…", "RegionID": 303 }

$ tailcat ping <jeton>
pong in 55.46ms via DERP(fra)

$ tailcat ping --until-direct --timeout=30s <jeton>
pong in 45.73ms via DERP(fra)
pong in 86.75ms via 192.168.1.20:53023        ← direct, en LAN
```

**Tailcat dit lui-même s'il est direct ou par DERP**, ce qui permet de le
vérifier au lieu de le croire. Le chemin part en DERP (Francfort,
`tc303a.ipn.dev` / 185.178.202.197) et passe direct quand on le pousse.

### `curl`, puis les mesures

Tunnel ssh tué d'abord, pour ne pas se mentir :

```
$ curl -s -m 3 -o /dev/null -w "8010:%{http_code}\n" http://127.0.0.1:8010/…
8010:000                                       ← plus aucun chemin

$ tailcat socks --listen=127.0.0.1:1080 <jeton> &
SOCKS running at socks5h://127.0.0.1:1080

$ curl -s --socks5-hostname 127.0.0.1:1080 http://server.tailcat:8010/_matrix/client/versions
{"versions":["r0.0.1",…,"v1.18"],"unstable_features":{…}}
```

| Mesure | Tailcat | Tunnel ssh |
|---|---|---|
| `/sync?timeout=0` (7 tirs) | 39 · 39 · 44 · 45 · 44 · 38 · 49 ms | 55 · 34 · 27 · 46 · 31 · 32 · 20 ms |
| médiane | **44 ms** | **32 ms** |
| téléversement d'un média de 5 Mio | 0,658 s — **7,97 Mo/s** | 0,596 s — **8,80 Mo/s** |
| téléchargement du même (3 tirs) | 0,64 / 0,58 / 0,71 s — **7,4 à 9,1 Mo/s** | 0,81 / 0,61 / 0,62 s — **6,5 à 8,7 Mo/s** |

Tailcat coûte une dizaine de millisecondes sur un aller-retour court et **rien de
mesurable sur un média** — les deux chemins se croisent d'un tir à l'autre. C'est
la conclusion qui compte : le débit ne décide pas.

### Le code d'appairage, étendu sans casser

Le jeton entre dans un champ **facultatif** du JSON. Quatre tests le tiennent :

- un code sans jeton se relit sans jeton ;
- le jeton fait l'aller-retour ;
- **un code d'hier se lit encore**, tel quel, sans être réémis ;
- une app d'hier qui décode le même JSON retrouve tous les champs qu'elle connaît
  et ignore celui qu'elle ne connaît pas ;
- **les six mots de vérification ne bougent pas** — ils nomment le Relais, pas le
  jeton, donc quelqu'un qui les a lus hier au téléphone retrouve les mêmes.

### L'app

`TailcatProxy` lance `tailcat socks --listen=127.0.0.1:0` en processus enfant et
**lit le port dans sa sortie** au lieu de le supposer — `:0` fait choisir le port
par le système, ce qui évite la collision avec un `tailcat` lancé à la main. Le
mandataire est posé **avant** le `/login` : posé après, le mot de passe serait
déjà parti par le chemin qu'on voulait éviter.

**Quatre choses qui ne se devinent pas.**

1. **Le mandataire de tailcat n'accepte que des noms.** `server.tailcat`, ou un
   addrblob ; **jamais** une IP littérale, qu'il comprend comme « sors par ce
   serveur vers cette adresse », c'est-à-dire un nœud de sortie — que notre
   Relais ne sert pas. Vérifié dans `classifySOCKSAddr`, et mesuré :
   `curl --socks5` (résolution locale) rend `000`, `--socks5-hostname` rend 200.
   Il fallait donc **vérifier** que le SOCKS5 de CFNetwork envoie le nom au
   mandataire au lieu de le résoudre d'abord. Il l'envoie.
2. **`kCFNetworkProxiesSOCKSEnable` vaut la chaîne `"SOCKSEnable"`.** Les écrire
   tous les deux dans le même littéral tue le processus au démarrage sur
   « Dictionary literal contains duplicate keys » — un `exit 133` sans un mot utile.
3. **La configuration d'une `URLSession` est figée à sa création.** Changer de
   mandataire demande d'en refaire une : sans `utiliserMandataire`, un code
   Tailcat n'aurait eu d'effet qu'au lancement suivant, silencieusement.
4. **App Transport Security refuse `http://server.tailcat`.** L'écran disait
   *« Le homeserver ne répond pas : the App Transport Security policy requires
   the use of a secure connection »* — c'est-à-dire qu'il accusait le Relais
   d'une panne qui n'était pas la sienne. L'exception se justifie et se justifie
   **par écrit dans l'`Info.plist`** : ce HTTP entre dans un tunnel WireGuard
   avant le premier octet sur le réseau.

### La preuve

`phase-7a-app-par-tailcat.png` : « Matrix live », les appareils listés, la
sauvegarde et la note à soi (`phase-7a-note-a-soi-tailcat.png`), avec pour tout
chemin un code d'appairage collé.

Et le fait qui décide, `lsof` :

```
=== connexions TCP de l'app ===
Correspon 52989  9u  IPv4  TCP 127.0.0.1:59792->127.0.0.1:59791 (ESTABLISHED)

=== le processus tailcat ===
tailcat 53016  5u  IPv6  UDP *:49327
tailcat 53016  6u  IPv4  UDP *:55679
tailcat 53016  7u  IPv4  TCP 192.168.1.41:59790->185.178.202.197:443 (ESTABLISHED)
tailcat 53016  8u  IPv4  TCP 127.0.0.1:59791 (LISTEN)
tailcat 53016  9u  IPv4  TCP 127.0.0.1:59791->127.0.0.1:59792 (ESTABLISHED)

=== l'app vers le NUC (192.168.1.20) en direct ? ===  AUCUNE
=== ssh -L ? ===                                      aucun
```

L'app n'a **qu'une** connexion TCP, et elle va au mandataire local. Le seul
chemin sortant est celui de tailcat : deux sockets UDP (WireGuard) et une
connexion au relais DERP de Francfort — `185.178.202.197`, que
`tailcat resolve` nomme `tc303a.ipn.dev`. Rien ne va au NUC en direct, et
Tailscale n'est pas dans le chemin (`tailscale` n'est même pas installé en CLI
sur ce Mac).

### Ce que ça impliquerait pour l'iPhone — sans le faire

Deux murs, tous deux découverts **par le compilateur** en construisant la cible
iOS, et tous deux définitifs pour cette approche-ci :

1. **`Process` n'existe pas sur iOS.** Une app iPhone ne lance pas de processus
   enfant ; `Foundation` n'expose même pas le type. Le modèle « l'app lance
   `tailcat socks` à côté d'elle » n'a pas d'équivalent. Il faudrait embarquer
   tailcat **dans** le binaire : c'est du Go, donc `gomobile bind` vers un
   XCFramework. **Le coût** : le runtime Go plus les paquets `tailscale.com`
   utilisés. Le binaire darwin arm64 complet pèse ici **29,3 Mio** non dépouillé ;
   une bibliothèque `gomobile` n'embarque pas la CLI mais garde le runtime, le
   ramasse-miettes et la pile WireGuard — compter **10 à 15 Mio par tranche**, à
   ajouter aux 22 Mio compressés que coûte déjà la machine crypto. C'est le
   chiffre à vérifier avant de s'engager, pas à supposer.
2. **`kCFNetworkProxiesSOCKS*` est marqué indisponible sur iOS.** CFNetwork n'y
   offre pas de mandataire SOCKS ; poser les clés en chaînes brutes compilerait
   et ne ferait rien, ce qui est pire qu'une erreur. Un tailcat embarqué devrait
   donc exposer autre chose — un `URLProtocol`, ou une socket locale que le
   client compose directement.

D'où `#if os(macOS)` sur tout le fichier, plutôt qu'un code qui compile et ne
fait rien. Sur iPhone, l'app joint le Relais comme avant.

---

## Les mesures, ensemble

| | Valeur |
|---|---|
| Chaîne Swift Linux posée sur ce Mac | toolchain 6.3.3-RELEASE + SDK `static-linux` 0.1.0 (musl 1.2.5) |
| `libmatrix_sdk_crypto_ffi.a` (musl x86-64) | **166,4 Mio**, 2 min 07 s |
| `cc` Linux **sans** crypto | 170,7 Mio · 23,5 s |
| `cc` Linux **avec** crypto | 224,3 Mio · 48,6 s → **87,7 Mio** dépouillé |
| RSS de `cc` sur le NUC (35 min) | **39,7 Mio** |
| tailcat NUC (linux amd64, publié) | 18,1 Mio · RSS 8,9 Mio |
| tailcat Mac (construit ici) | 29,3 Mio · 37,6 s |
| `/sync` médian, tailcat / ssh | **44 ms / 32 ms** |
| média 5 Mio, tailcat / ssh | **7,4–9,1 Mo/s / 6,5–8,7 Mo/s** |
| Chemin tailcat | DERP(fra) d'abord, **direct 192.168.1.20 quand on le pousse** |
| Tests | **823** sans crypto, **828** avec |

---

## Rejouer

```bash
cd ~/correspondance-un-clic

# 0. La chaîne Linux (une fois ; le script dit ce qui manque au lieu d'échouer)
bash infra/relais/crypto-linux.sh --verifier
bash infra/relais/crypto-linux.sh                    # ~2 min

# 1. cc chiffré pour Linux
TC=$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin
cd Packages/CorrespondanceCore
CORRESPONDANCE_CRYPTO=1 \
CORRESPONDANCE_CRYPTO_LINUX=$HOME/.correspondance-unclic/crypto-linux/x86_64 \
  $TC/swift build --product correspondance-agent -c release \
  --swift-sdk x86_64-swift-linux-musl --scratch-path /tmp/build-unclic-linux-crypto
cd ../..

# Le Relais du spike sur le NUC, puis le binaire, puis la preuve
scp infra/relais/install.sh nuc:/tmp/ && ssh nuc 'cd /tmp && bash install.sh --prefix ~/unclic'
scp /tmp/build-unclic-linux-crypto/release/correspondance-agent nuc:/tmp/cc-unclic
ssh nuc 'mkdir -p ~/unclic/bin && strip /tmp/cc-unclic && mv /tmp/cc-unclic ~/unclic/bin/correspondance-agent && chmod 755 $_'
CORRESPONDANCE_CRYPTO=1 swift build --package-path Packages/CorrespondanceCore --scratch-path /tmp/build-unclic-crypto
bash infra/relais-spike/preuve-cc-linux.sh

# 2. Les deux écrans (écran ALLUMÉ, sinon la capture est noire)
CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Debug -derivedDataPath /tmp/dd-unclic build
CORRESPONDANCE_HOME=unclic /tmp/dd-unclic/Build/Products/Debug/Correspondance.app/Contents/MacOS/Correspondance
#   Réglages › Serveur Matrix, coller le code → Phrase de récupération, Appareils

# 3. Tailcat
ssh nuc 'mkdir -p ~/unclic/tailcat && cd ~/unclic/tailcat && \
  curl -fsSLO https://github.com/tailscale/tailcat/releases/download/v0.4.0/tailcat_0.4.0_linux_amd64.tar.gz && \
  sha256sum tailcat_0.4.0_linux_amd64.tar.gz && tar xzf tailcat_0.4.0_linux_amd64.tar.gz && \
  ./tailcat genkey --key=relais'
(cd ~/.correspondance-unclic-src && git clone --depth 1 --branch v0.4.0 \
  https://github.com/tailscale/tailcat.git tailcat && cd tailcat && \
  GOFLAGS=-trimpath go build -o ~/.correspondance-unclic/tailcat ./cmd/tailcat)
~/.correspondance-unclic/tailcat ping --until-direct <jeton>
CORRESPONDANCE_HOME=unclic CORRESPONDANCE_TAILCAT=$HOME/.correspondance-unclic/tailcat \
  /tmp/dd-unclic/Build/Products/Debug/Correspondance.app/Contents/MacOS/Correspondance

# Les tests, dans les deux configurations. Scratch séparés — obligatoire.
cd Packages/CorrespondanceCore && rm -rf .build
swift test --scratch-path /tmp/build-unclic-sanscrypto                       # 823
rm -rf .build
CORRESPONDANCE_CRYPTO=1 swift test --scratch-path /tmp/build-unclic-crypto   # 828

# Ne rien laisser
ssh nuc 'systemctl --user disable --now unclic-cc unclic-tailcat; rm -f ~/.config/systemd/user/unclic-*.service; systemctl --user daemon-reload'
ssh nuc 'cd /tmp && bash uninstall.sh --prefix ~/unclic && rm -rf ~/unclic'
bash infra/relais/uninstall.sh
```

---

## Ce qui reste

1. **La `.a` Linux n'est pas publiée.** Elle pèse 166 Mio et se reconstruit en
   2 min ; ce qui doit être publié, c'est le **binaire `cc`** qui la contient
   (87,7 Mio dépouillé), et `infra/agent/install.sh` le télécharge déjà. Reste à
   basculer `infra/agent/deploy.sh` de « Docker sur le NUC » à « croisé sur la
   machine de construction » — la chaîne existe maintenant.
2. **`correspondance-agent-linux-arm64`** n'est pas construit : le SDK statique
   porte la tranche `aarch64`, mais la `.a` Rust devrait l'être aussi
   (`aarch64-unknown-linux-musl`, même recette).
3. **Un binaire tailcat macOS à publier et à signer**, comme les quatre ponts.
4. **L'iPhone par Tailcat** : `gomobile bind`, et une façon de composer sans SOCKS.
   Chiffrer le coût avant de s'engager (cf. plus haut).
5. **L'App Group `group.com.correspondance`**, toujours absent du portail
   développeur — il bloque encore l'extension de notification.
6. **Une capture iOS** des deux écrans, qui demande d'appairer un simulateur.

## État des deux machines à la fin

- **Ce Mac** : la chaîne Linux reste installée (toolchain + SDK, ~2,5 Gio) —
  c'est le livrable, pas un résidu. `~/.correspondance-unclic/` porte la `.a`, le
  binaire tailcat et le magasin de la preuve ; `~/.correspondance-unclic-src/`
  porte les sources épinglées. Aucun processus orphelin.
- **Le NUC** : `~/unclic/` et les unités `unclic-cc` / `unclic-tailcat` à retirer
  par les commandes ci-dessus. La production n'a jamais été interrompue — les
  trois agents `correspondance-cc`, `-hermes` et `-claude` sont restés `active`
  du début à la fin, et le dossier `crypto/` posé par erreur dans
  `~/.correspondance-agent/` a été retiré.
