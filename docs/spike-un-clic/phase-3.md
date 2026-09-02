# Phase 3 — La pile en binaires, posée par une commande, sur Mac et sur Linux

Éprouvé le 2 septembre 2026. Sur le Mac de développement (arm64, macOS 26.6.2, sans Docker),
tout vit sous `~/.correspondance-unclic/` ; sur le NUC (`ssh nuc`, Debian 12, x86_64, Docker
présent mais **jamais utilisé ici**), tout vit sous `~/unclic/`. Les deux Relais écoutent sur
`127.0.0.1:8010`, les ponts sur 29318 et 29328. Ce qui reproduit tout est dans
`infra/relais/` : `install.sh`, `uninstall.sh`, `tests/install-plan.sh`.

**Verdict** : *une commande suffit, sur les deux hôtes, et elle finit sur la preuve puis sur le
code que l'app lit.* **7,2 s sur le Mac** (Continuwuity servi localement, ponts téléchargés) et
**21,7 s sur le NUC** depuis un dossier vide, téléchargements compris. L'app se connecte aux
deux : au Relais du Mac en direct, à celui du NUC par `ssh -N -L`. Il reste **deux binaires à
publier** pour que la carte « sur ce Mac » existe pour de vrai : Continuwuity macOS arm64 et
`libolm.3.dylib`, tous deux construits par nous, à signer et notariser.

---

## 1. Ce que l'installeur fait, et ce qu'il ne fait pas

```
infra/relais/
  install.sh           détecte l'hôte, télécharge, configure, pose les services, prouve, appaire
  uninstall.sh         retire les services puis le dossier — et refuse un dossier qui n'est pas le sien
  tests/install-plan.sh  éprouve le --dry-run des trois hôtes, les refus, et l'idempotence
```

Options : `--dry-run`, `--prefix`, `--port`, `--server-name`, `--user`, `--bind`,
`--sans-ponts`, et `--hote` qui **force** la cible (`macos-arm64` / `linux-x86_64` /
`linux-arm64`) pour qu'une seule machine puisse éprouver le plan des trois.

Il n'utilise **ni sudo, ni Docker, ni Homebrew, ni Go, ni cargo** : tout est binaire, épinglé,
et vérifié par sha256 avant d'être posé. Il n'installe **jamais Tailscale** — il le détecte,
s'en sert s'il est là, et dit ce qu'il faudrait faire sinon (§ 4).

### Les binaires épinglés

| Hôte | Continuwuity | sha256 | Ponts |
|---|---|---|---|
| macOS arm64 | `continuwuity-macos-arm64` de **notre** publication (construit en phase 1 au tag `v26.8.1`) | `a7b4dd20…16f77` | `mautrix-*-darwin-arm64` `v0.2608.0` + `libolm.3.dylib` (`d946defe…07168`) |
| Linux x86_64 | `conduwuit-linux-static-amd64` `v26.8.1`, release amont | `43bcf0e4…ed02d` | `mautrix-*-amd64` `v0.2608.0` |
| Linux arm64 | `conduwuit-linux-static-arm64` `v26.8.1`, release amont | `28d0a92c…a38c15` | `mautrix-*-arm64` `v0.2608.0` |

Les sommes des ponts sont celles des `sha256sums.txt` publiés par mautrix. Celles de
Continuwuity **n'existent pas en amont** : l'amont ne publie aucun fichier de sommes, elles ont
donc été relevées ici, une fois, sur les binaires téléchargés, et écrites dans le script. La
somme du binaire macOS et celle de libolm sont celles des binaires construits en phase 1.

Pour ce spike, les deux fichiers macOS sont servis depuis un dossier local :

```
$ ls ~/unclic-publication
SHA256SUMS  continuwuity-macos-arm64  libolm.3.dylib
$ cd ~/unclic-publication && python3 -m http.server 8020 --bind 127.0.0.1 &
$ CORRESPONDANCE_RELEASES=http://127.0.0.1:8020 bash infra/relais/install.sh
```

Sans cette variable, l'installeur les cherche à
`https://github.com/menufactory43/correspondance-releases/releases/latest/download/…` — ce qui
n'existe pas encore (§ 7).

### Les six choses que l'installeur sait, et que le plan ne disait pas

1. **Le jeton d'amorçage se lit dans le journal, et il arrive après le port.** Continuwuity
   ouvre son port, puis imprime son bandeau d'accueil avec le jeton à usage unique. Lire le
   journal une seule fois marche sur le Mac et rate sur le NUC : la première version de
   l'installeur y est tombée sur `Invalid registration token`. Il attend maintenant que le
   jeton paraisse, vingt secondes au plus.
2. **`launchctl bootout` rend la main avant que le service ait disparu.** Enchaîner
   `bootstrap` donne `Bootstrap failed: 5: Input/output error`, et la **deuxième** exécution
   de l'installeur échouait là. Il attend que `launchctl print` ne trouve plus rien.
3. **Le python3 du système, sur macOS, n'a pas PyYAML.** `infra/matrix/merge-overrides.py`
   ne peut donc pas servir sur une machine vierge. La parade est meilleure que la fusion :
   on n'écrit **que nos choix** dans `config.yaml`, et le pont complète tout le reste
   lui-même au premier démarrage (son « config upgrade »). Zéro dépendance Python en plus.
4. **Sans `logging.writers`, un pont mautrix n'écrit rien du tout.** Le configurateur amont
   ne complète pas cette liste quand la section existe déjà, et zerolog se tait — deux
   journaux de zéro octet, et aucune idée de ce que fait le pont. Il faut l'écrire.
5. **Une registration ne s'engendre qu'une fois.** `-g` retire de nouveaux jetons dans
   `config.yaml` ; sur une pile déjà enregistrée, le pont répond alors « The as_token was not
   accepted ». L'installeur ne le fait que si `registration.yaml` manque.
6. **Les services des ponts démarrent APRÈS l'enregistrement de l'appservice**, sinon ils
   bouclent sur un jeton refusé, avec `KeepAlive` / `Restart=always` pour les y aider.

---

## 2. Preuve Mac — transcription complète

Dossier effacé (les binaires de la phase 1 avaient été mis à l'abri dans
`~/unclic-publication/` d'abord), aucun service chargé, une seule commande, aucune question.

```
$ ls -d ~/.correspondance-unclic
ls: ~/.correspondance-unclic: No such file or directory

$ launchctl list | grep correspondance
(aucun)

$ time CORRESPONDANCE_RELEASES=http://127.0.0.1:8020 bash infra/relais/install.sh
→ hôte macos-arm64 — tout vit sous ~/.correspondance-unclic
→ continuwuity ← http://127.0.0.1:8020/continuwuity-macos-arm64
→ continuwuity : sha256 a7b4dd2099dd349631b24c3f3970cb440fb9365a3aa406830995d389fae16f77 ✓
→ libolm.3.dylib ← http://127.0.0.1:8020/libolm.3.dylib
→ libolm.3.dylib : sha256 d946defe44adc62d706b3acde6a6904532f32abe4ef7e0096ec08d273ee07168 ✓
→ mautrix-whatsapp ← https://github.com/mautrix/whatsapp/releases/download/v0.2608.0/mautrix-whatsapp-darwin-arm64
→ mautrix-whatsapp : sha256 938242a121df389706dc00e6cbdd9b6fedd267963e3eaddd2ee701c6ddeb4808 ✓
→ mautrix-signal ← https://github.com/mautrix/signal/releases/download/v0.2608.0/mautrix-signal-darwin-arm64
→ mautrix-signal : sha256 9d48db00fb3e7e7382d7b165a90e4952a6902d18ecf304436c29fc8cc216e586 ✓
→ secrets tirés dans ~/.correspondance-unclic/secrets.env (0600, hors dépôt)
→ écrit ~/.correspondance-unclic/relais/continuwuity.toml
→ service app.correspondance.relais chargé (journal …/logs/relais.log)
→ attente du Relais sur http://127.0.0.1:8010
→ ✓ le Relais répond ({"name":"continuwuity","version":"26.8.1 (ab3c05d)"})
→ jeton d'amorçage relevé dans le journal du Relais
→ enregistrement de @essai:unclic.local
→ ✓ @essai:unclic.local enregistré
→ mautrix-whatsapp : configuration écrite
→ mautrix-whatsapp : registration engendrée
→ appservice whatsapp : Appservice registered with ID: whatsapp
→ service app.correspondance.mautrix-whatsapp chargé (journal …/logs/mautrix-whatsapp.log)
→ mautrix-signal : configuration écrite
→ mautrix-signal : registration engendrée
→ appservice signal : Appservice registered with ID: signal
→ service app.correspondance.mautrix-signal chargé (journal …/logs/mautrix-signal.log)

✓ le Relais répond, connecté comme @essai:unclic.local (/login puis /account/whoami).
  Ponts : mautrix-whatsapp sur 29318, mautrix-signal sur 29328 — portails chiffrés.
  macOS : Tailscale n'est ni posé ni requis. Le Relais et l'app sont sur la même machine,
  le code portera http://127.0.0.1:8010.

  Relais prêt. Dans Correspondance : « Connecter un Relais », puis colle ce code.

  correspondance://relais/eyJleHAiOjE3ODgzMDc2NTYuODY5MjA0LCJob21lc2VydmVyIjoiaHR0cDovLzEy…
                          (tronqué : il porte un mot de passe)

  Vérification (six mots) : usine marée dune chêne zeste encre
  Il périme dans 15 minutes. Il contient un mot de passe : ne le poste nulle part.

  Le Relais revient tout seul : launchctl kickstart -k gui/501/app.correspondance.relais
  Tout retirer : bash uninstall.sh --prefix ~/.correspondance-unclic

bash infra/relais/install.sh  1.31s user 0.61s system 26% cpu  7.156 total
```

Les six mots sont les mêmes qu'en phase 1 : ils se calculent sur l'identité du Relais
(adresse, nom, propriétaire), pas sur le mot de passe — un code réémis donne les mêmes.

### La pile tourne vraiment

```
$ launchctl list | grep correspondance
34006	0	app.correspondance.mautrix-signal
33981	0	app.correspondance.mautrix-whatsapp
33943	0	app.correspondance.relais

$ lsof -nP -iTCP -sTCP:LISTEN | grep -E '8010|29318|29328'
continuwu 33943 … TCP 127.0.0.1:8010 (LISTEN)
mautrix-w 33981 … TCP 127.0.0.1:29318 (LISTEN)
mautrix-s 34006 … TCP 127.0.0.1:29328 (LISTEN)

$ grep -E 'not accepted|ERR |Bridge started' ~/.correspondance-unclic/logs/mautrix-*.log
mautrix-whatsapp.log:2026-09-02T01:52:35.685+02:00 INF Bridge started
mautrix-signal.log:2026-09-02T01:52:36.636+02:00 INF Bridge started
```

### L'app se connecte

`xcodebuild … -derivedDataPath /tmp/dd-unclic` puis, l'exécutable lancé directement avec
l'environnement en préfixe (pas `open --env`, cf. phase 2) :

```
$ CORRESPONDANCE_HOME=unclic /tmp/dd-unclic/Build/Products/Debug/Correspondance.app/Contents/MacOS/Correspondance
```

Réglages › Serveur Matrix, le code collé dans « Connecter un Relais » :

![L'app connectée au Relais posé par l'installeur](phase-3-app-mac.png)

*« Correspondance-unclic », « Matrix live · aucun fil bridgé », « Synchronisé avec le Relais ».*

Et la contre-preuve, côté Relais — la session de l'app existe pour de bon :

```
$ python3 ~/.correspondance-unclic/outils/salon-admin.py http://127.0.0.1:8010 "$T" unclic.local \
    '!admin query users list-devices-metadata @essai:unclic.local'
[
    Device { device_id: "CvTKwcDn8W", display_name: Some("relais-install"), … },
    Device { device_id: "qmVCsB988W", display_name: Some("Correspondance (Mac)"),
             last_seen_ip: Some("127.0.0.1"), last_seen_ts: Some(2026-09-01T23:59:27.899) },
]
```

Note d'automatisation, qui prolonge celle de la phase 1 : un `click at {x, y}` sur le champ du
code **ne le focalise pas**, et le `⌘V` part alors ailleurs — le champ reste vide sans que rien
ne le dise. Ce qui marche : `set focused of text field 1 … to true`, puis `⌘V`, puis Entrée
(le `TextField` a un `.onSubmit`).

### Le Relais revient seul

```
$ launchctl kickstart -k gui/501/app.correspondance.relais     # SIGKILL, launchd relance
01:53:12.614 → 01:53:18.096   soit 5,5 s (dont l'attente de relance de launchd)

$ launchctl bootout gui/501/app.correspondance.relais          # « fin de session »
$ lsof -nP -iTCP:8010 -sTCP:LISTEN
8010 libre
$ launchctl bootstrap gui/501 ~/Library/LaunchAgents/app.correspondance.relais.plist
bootstrap → première réponse : 0.27 s
{"name":"continuwuity","version":"26.8.1 (ab3c05d)"}
```

### Idempotence

```
$ bash infra/relais/install.sh   (deuxième fois, pile déjà en marche)
→ continuwuity déjà posé, sha256 conforme
→ libolm.3.dylib déjà posé, sha256 conforme
→ mautrix-whatsapp déjà posé, sha256 conforme
→ mautrix-signal déjà posé, sha256 conforme
→ …/relais/continuwuity.toml déjà là, conservé
→ service app.correspondance.relais chargé
→ ✓ le Relais répond
→ compte @essai:unclic.local déjà là, session valide
→ mautrix-whatsapp : configuration déjà là, conservée
→ mautrix-whatsapp : registration déjà là, jetons inchangés
→ mautrix-signal : configuration déjà là, conservée
→ mautrix-signal : registration déjà là, jetons inchangés
✓ le Relais répond, connecté comme @essai:unclic.local
…  2.220 total
```

Rien n'est réécrit ; seul le mot de passe du propriétaire est reposé (par `#admins`, **sans**
`--logout`, donc les sessions ouvertes survivent) pour que le nouveau code soit valide.

---

## 3. Preuve Linux (le NUC) — transcription complète

`~/unclic/` n'existe pas, aucune unité `correspondance-relais`, Docker tourne (36 conteneurs
de la prod) et **n'est pas touché**. Le script a été copié par `scp` dans `/tmp` — pas de
`curl | sh`, pour la raison écrite dans l'installeur de l'agent (commit `d59bf27`).

```
$ ls -d ~/unclic
ls: impossible d'accéder à '/home/meff/unclic': Aucun fichier ou dossier de ce type

$ docker ps -q | wc -l          # Docker existe, on ne s'en sert pas
36

$ time bash /tmp/install.sh --prefix $HOME/unclic
→ hôte linux-x86_64 — tout vit sous /home/meff/unclic
→ continuwuity ← https://forgejo.ellis.link/…/v26.8.1/conduwuit-linux-static-amd64
→ continuwuity : sha256 43bcf0e41a60219fe96673e6ed7c041cca1aee42d1758bfeccb571f89f4ed02d ✓
→ mautrix-whatsapp ← https://github.com/mautrix/whatsapp/releases/download/v0.2608.0/mautrix-whatsapp-amd64
→ mautrix-whatsapp : sha256 dc519ea63f34dd0b0b33bffda1dc671360ba9e7f806d77ba9849b9586540e4f5 ✓
→ mautrix-signal ← https://github.com/mautrix/signal/releases/download/v0.2608.0/mautrix-signal-amd64
→ mautrix-signal : sha256 ab373049f98c3f1b48b3a386bc91166be401eda61176e2d528902f5d22c47afa ✓
→ secrets tirés dans /home/meff/unclic/secrets.env (0600, hors dépôt)
→ écrit /home/meff/unclic/relais/continuwuity.toml
→ linger déjà activé pour meff
Created symlink …/default.target.wants/correspondance-relais.service → …/correspondance-relais.service
→ service correspondance-relais démarré (journal /home/meff/unclic/logs/relais.log)
→ attente du Relais sur http://127.0.0.1:8010
→ ✓ le Relais répond ({"name":"continuwuity","version":"26.8.1 (ab3c05d)"})
→ jeton d'amorçage relevé dans le journal du Relais
→ enregistrement de @essai:unclic.local
→ ✓ @essai:unclic.local enregistré
→ mautrix-whatsapp : configuration écrite
→ mautrix-whatsapp : registration engendrée
→ appservice whatsapp : Appservice registered with ID: whatsapp
→ service correspondance-mautrix-whatsapp démarré
→ mautrix-signal : configuration écrite
→ mautrix-signal : registration engendrée
→ appservice signal : Appservice registered with ID: signal
→ service correspondance-mautrix-signal démarré

✓ le Relais répond, connecté comme @essai:unclic.local (/login puis /account/whoami).
  Ponts : mautrix-whatsapp sur 29318, mautrix-signal sur 29328 — portails chiffrés.
  Tailscale absent. Cet installeur ne le pose PAS (ça demande sudo : curl -fsSL
  https://tailscale.com/install.sh | sh, puis sudo tailscale up). Le code portera
  http://127.0.0.1:8010 — joignable depuis un autre poste par :
  ssh -N -L 8010:127.0.0.1:8010 <cette machine>.

  Relais prêt. Dans Correspondance : « Connecter un Relais », puis colle ce code.

  correspondance://relais/eyJleHAiOjE3ODgzMDc4NjYuODI3NjQzMiwiaG9tZXNlcnZlciI6Imh0dHA6Ly8xMj…
  Vérification (six mots) : usine marée dune chêne zeste encre

  Le Relais revient tout seul : systemctl --user restart correspondance-relais
  Tout retirer : bash uninstall.sh --prefix /home/meff/unclic

real	0m21,692s
```

```
$ systemctl --user status correspondance-relais correspondance-mautrix-{whatsapp,signal}
● correspondance-relais.service            Active: active (running)  Main PID: 1016470 (continuwuity)
● correspondance-mautrix-whatsapp.service  Active: active (running)  Main PID: 1016584
● correspondance-mautrix-signal.service    Active: active (running)  Main PID: 1016640

$ ss -ltnp | grep -E ':8010|:29318|:29328'
127.0.0.1:8010   users:(("continuwuity",pid=1016470,fd=134))
127.0.0.1:29328  users:(("mautrix-signal",pid=1016640,fd=10))
127.0.0.1:29318  users:(("mautrix-whatsap",pid=1016584,fd=9))

$ grep -iE 'not accepted|ERR |FATAL' ~/unclic/logs/mautrix-*.log
(aucune)
```

### L'app du Mac se connecte au Relais du NUC, par le tunnel

Le NUC n'expose que `127.0.0.1` : le code porte donc `http://127.0.0.1:8010`, exactement
comme le Relais d'essai, et c'est le tunnel qui fait le reste.

```
(sur le Mac)  $ launchctl bootout gui/501/app.correspondance.{relais,mautrix-*}   # libérer 8010
              $ ssh -N -L 8010:127.0.0.1:8010 nuc &
              $ curl -s http://127.0.0.1:8010/_continuwuity/server_version
              {"name":"continuwuity","version":"26.8.1 (ab3c05d)"}
```

Code collé dans l'app, même chemin qu'au § 2 :

![L'app connectée au Relais du NUC par le tunnel](phase-3-app-nuc.png)

Et la contre-preuve, prise **sur le NUC** :

```
(sur le NUC)  $ python3 ~/unclic/outils/salon-admin.py http://127.0.0.1:8010 "$T" unclic.local \
                  '!admin query users list-devices-metadata @essai:unclic.local'
[
    Device { device_id: "3mUxgWi4yR", display_name: Some("relais-install"), … },
    Device { device_id: "oeunecfc0s", display_name: Some("Correspondance (Mac)"),
             last_seen_ts: Some(2026-09-02T00:00:22.357) },
]

(sur le Mac)  $ launchctl list | grep correspondance
              aucun service Relais chargé sur le Mac
              $ lsof -nP -iTCP:8010 -sTCP:LISTEN
              ssh  36658  … TCP 127.0.0.1:8010 (LISTEN)
```

Rien n'écoutait sur le Mac que le tunnel : la session « Correspondance (Mac) » est bien sur le
Relais du NUC.

### Il revient

```
$ systemctl --user restart correspondance-relais
systemctl restart rend la main en 0,05 s ; première réponse 0,36 s après le début
{"name":"continuwuity","version":"26.8.1 (ab3c05d)"}
```

**Une nuance mesurée** : quand un client tient un `/sync` ouvert, ce n'est pas le démarrage
qui coûte, c'est l'arrêt.

```
$ systemctl --user stop correspondance-relais ; systemctl --user start correspondance-relais
arrêt 15,03 s ; démarrage jusqu'à la première réponse 0,33 s
```

Continuwuity attend ses longues requêtes avant de sortir. Un `restart` avec l'app connectée a
donc pris 15,7 s bout à bout. Ça ne se voit pas sur une pile au repos (0,36 s), et il faudra
s'en souvenir le jour où un « redémarrer le Relais » apparaîtra dans l'app.

### Idempotence, sur le NUC aussi

```
$ bash /tmp/install.sh --prefix $HOME/unclic     (deuxième passage)
→ compte @essai:unclic.local déjà là, session valide
→ mautrix-whatsapp : configuration déjà là, conservée
→ mautrix-whatsapp : registration déjà là, jetons inchangés
→ mautrix-signal : configuration déjà là, conservée
→ mautrix-signal : registration déjà là, jetons inchangés
✓ le Relais répond, connecté comme @essai:unclic.local
real	0m1,990s
```

---

## 4. Tailscale, et l'adresse dans le code

Le NUC **n'a pas** Tailscale (`command -v tailscale` : absent, `tailscaled` inactif, aucune
interface `tailscale0`) — contrairement à ce qu'on croyait. C'est en fait le meilleur des cas
pour éprouver la règle : l'installeur ne pose rien, le dit, et donne la solution de rechange.

- **Présent** : `tailscale ip -4` donne l'adresse, le code porte `http://<ip tailnet>:<port>`
  et le `.toml` écoute **aussi** sur cette adresse (`address = ["127.0.0.1", "<ip>"]`).
  Ce chemin n'a **pas** pu être éprouvé ici : à noter comme non vérifié.
- **Absent** : le code porte `http://127.0.0.1:<port>`, et l'installeur imprime la commande
  qu'il **ne** lance pas (`curl -fsSL https://tailscale.com/install.sh | sh`, puis
  `sudo tailscale up`) plus le tunnel qui marche tout de suite :
  `ssh -N -L 8010:127.0.0.1:8010 <machine>`.
- **Sur macOS** : jamais posé, jamais requis — le Relais et l'app sont sur la même machine.

`loginctl enable-linger` : déjà actif sur le NUC, donc l'installeur le dit et passe. S'il
échoue faute de privilège, il imprime `sudo loginctl enable-linger <user>` et **continue** —
sans linger, tout meurt à la déconnexion SSH, ce qu'il dit aussi.

---

## 5. Les mesures

| | Mac (arm64) | NUC (x86_64) |
|---|---|---|
| **Temps total de la commande, dossier vide** | **7,16 s** | **21,69 s** |
| dont téléchargements | ponts (78 Mo) depuis GitHub ; Continuwuity et libolm en local | 196 Mo depuis forgejo + GitHub |
| Deuxième passage (idempotence) | 2,22 s | 1,99 s |
| Relais, RSS au repos | 35,3 Mo (41,8 Mo à la 25ᵉ seconde) | 66,8 Mo |
| Pont WhatsApp, RSS | 23,2 Mo | 30,4 Mo |
| Pont Signal, RSS | 21,1 Mo | 32,7 Mo |
| **Total de la pile** | **79,6 Mo** (94 Mo au démarrage) | **130 Mo** |
| Démarrage du Relais (service relancé) | 0,27 s | 0,33 s |
| Arrêt, avec un client en `/sync` | — | 15,0 s |
| Disque, tout compris | 221 Mo | 259 Mo |
| dont binaires | 217 Mo (Continuwuity 80,7 + Signal 86,7 + WhatsApp 45,7 + libolm 0,19) | 188 Mo (Continuwuity 109,3 + Signal 54,9 + WhatsApp 32,0) |
| dont base du Relais | 1,6 Mo | 70 Mo |

Trois remarques honnêtes.

1. **Les 70 Mo de base du NUC contre 1,6 Mo sur le Mac** : c'est RocksDB qui préalloue son WAL
   sur un build Linux (io_uring, jemalloc) là où le build macOS de la phase 1 ne le fait pas.
   Ce n'est pas de l'historique — les deux Relais ont le même contenu.
2. **La mémoire monte quand la pile vient de démarrer** et redescend ensuite : la phase 1 avait
   relevé 46 Mo au repos et 107 Mo au démarrage, le vérificateur avait demandé qu'on dise les
   deux. Ici, 94 Mo à la 25ᵉ seconde et 79,6 Mo trois minutes plus tard sur le Mac, avec deux ponts qui ont chargé
   leur machine crypto. Retenir « 80 à 130 Mo » pour une pile posée du jour, contre les
   **620 Mo** de Synapse + Postgres du NUC.
3. Les binaires Linux sont plus gros mais la pile y consomme plus : le build statique embarque
   sa libc, et le Relais du NUC a servi l'app.

---

## 6. Les tests

`infra/relais/tests/install-plan.sh`, dans l'esprit de `infra/matrix/tests/install-plan.sh` :
il éprouve le plan des trois hôtes depuis une seule machine (`--hote`), les refus, le
désinstalleur, et l'idempotence par lecture du script — c'est-à-dire les six phrases qui
disent « je conserve ce qui existe ».

```
$ bash infra/relais/tests/install-plan.sh
Hôte « macos-arm64 »
  ✓ prend le binaire macOS de NOTRE publication
  ✓ pose libolm à côté des ponts
  ✓ prend les ponts darwin-arm64 d'amont
  ✓ pose un agent launchd utilisateur
  ✓ dit qu'il ne pose pas Tailscale sur Mac
  ✓ finit sur la preuve
  ✓ finit sur le code d'appairage
  ✓ n'exécute rien
  ✓ aucun systemd sur Mac
  ✓ annonce qu'il n'y a ni sudo ni Docker
  ✓ ne demande aucun sudo sur Mac
  ✓ ne pose pas Tailscale sur Mac
Hôte « linux-x86_64 »
  ✓ prend la release amont, statique, amd64
  ✓ prend les ponts amd64
  ✓ pose une unité systemd utilisateur
  ✓ parle du linger
  ✓ respecte --prefix
  ✓ aucun launchd sur Linux
  ✓ ne pose pas libolm sur Linux
Hôte « linux-arm64 »
  ✓ prend la release amont, statique, arm64
  ✓ prend les ponts arm64
  ✓ ne confond pas avec l'amd64
Tailscale, quand il manque
  ✓ dit ce qu'il ferait, et que ça demande sudo
  ✓ propose le tunnel ssh en attendant
Les options
  ✓ déplace le Relais avec --port
  ✓ déplace les ponts avec lui
  ✓ reprend --server-name et --user
Les refus
  ✓ refuse un hôte inconnu
  ✓ refuse une option inconnue
  ✓ refuse /Users/…/.correspondance-agent (prod)
  ✓ refuse /Users/…/Library/Application Support/Correspondance (prod)
Le désinstalleur
  ✓ refuse d'effacer un dossier sans la marque de l'installeur
  ✓ efface un dossier qui porte la marque
L'idempotence des écritures
  ✓ ne réécrit pas le .toml existant
  ✓ ne réécrit pas la config d'un pont existante
  ✓ ne retire pas de nouveaux jetons de pont
  ✓ ne retire pas de nouveaux secrets
  ✓ ne recrée pas le compte si la session vaut encore
  ✓ refuse d'installer si un sha256 diffère

Plan d'installation du Relais : tout est conforme.
```

Ce que ça ne prouve pas, et il faut le dire : que Continuwuity démarre, que les ponts
s'enregistrent, que le code marche. Ça, ce sont les deux transcriptions ci-dessus.

---

## 7. Ce qui manque pour la carte « sur ce Mac » dans l'app

L'app devrait, en un bouton : lancer l'installeur, montrer ses lignes, et **coller le code
elle-même**. Il manque quatre choses, dont une seule est du travail d'app.

1. **Les deux binaires macOS publiés** (§ ci-dessous). Sans eux, la carte ne peut rien
   télécharger. C'est le vrai bloqueur.
2. **Un mode « machine » de l'installeur**. Aujourd'hui il imprime pour un humain. La carte
   veut un flux lisible par programme : `--json`, une ligne par étape
   (`{"etape":"binaire","nom":"continuwuity","fait":true}`), et le code d'appairage comme
   **dernier objet** au lieu d'un paragraphe. Une heure de travail, pas plus.
3. **Le collage automatique**. `RelayPairingCode(encoded:)` existe déjà côté Swift : la carte
   n'a pas à passer par le champ de texte, elle appelle le même chemin que
   `SettingsMatrixPane.appairer()` avec le code que l'installeur vient de rendre. Zéro
   nouveauté de protocole.
4. **Le bac à sable**. Une app signée qui lance un script, pose des `LaunchAgents` et écrit
   dans `~/Library/LaunchAgents` sort du bac à sable App Store. Correspondance se distribue
   déjà hors App Store (DMG notarisé) : la carte est possible, mais il faut le décider, et
   l'installeur doit continuer d'exister comme commande pour les autres hôtes.

Ce qui **ne** manque pas : les quatre appels `_synapse/admin` de la matrice de la phase 1 ne
sont sur le chemin de rien ici. L'installeur, lui, s'en passe déjà entièrement — il parle à
`#admins` (`outils/salon-admin.py`), c'est-à-dire qu'il prouve en Python les 90 lignes que le
Swift devra écrire.

---

## 8. Ce que la publication dans `correspondance-releases` demande

Le dépôt public `correspondance-releases` ne porte aujourd'hui que l'installeur de l'agent et
ses binaires. Pour le Relais, il faut y ajouter :

| Fichier | D'où il vient | Ce que ça coûte |
|---|---|---|
| `relais-install.sh` | ce dépôt, `infra/relais/install.sh` | rien — un fichier |
| `continuwuity-macos-arm64` | **à construire** : tag `v26.8.1`, `cargo build --release --no-default-features --features brotli_compression,element_hacks,gzip_compression,media_thumbnail,ring,url_preview,zstd_compression,bindgen-runtime,console` | ~20 min à froid, 2,6 Go de sources. À refaire à chaque mise à jour de Continuwuity. |
| `libolm.3.dylib` | **à construire** : olm `3.2.16`, plus la correction d'un caractère dans `include/olm/list.hh` (Apple clang 21 refuse un `operator=` sur un `T * const`) | 190 Ko, deux minutes |
| — | rien pour Linux : les releases amont suffisent, x86_64 et arm64 | — |

Trois choses à décider avant de publier.

1. **La signature et la notarisation.** Un binaire téléchargé par `curl` porte l'attribut de
   quarantaine ; l'installeur le retire (`xattr -d com.apple.quarantine`), ce qui suffit
   **tant que l'utilisateur lance l'installeur depuis un terminal**. Le jour où c'est l'app
   qui les pose, Gatekeeper les évalue : il faudra signer `continuwuity`, `libolm.3.dylib` et
   les deux ponts avec l'identité Developer ID, et notariser le tout. Les ponts mautrix
   amont **ne sont pas signés** : il faudra les re-signer nous-mêmes, ce qui veut dire les
   republier chez nous plutôt que de pointer sur GitHub.
2. **La dette `goolm`.** Reconstruire les ponts avec `-tags goolm` (olm réimplémenté en Go,
   sans cgo) ferait disparaître `libolm.3.dylib` et un binaire à signer. Ça demande Go sur la
   machine de publication — ce n'est pas un obstacle pour une chaîne de publication, seulement
   pour l'installeur, qui ne doit rien construire. **Recommandé** : construire les ponts
   nous-mêmes en `goolm`, les signer, et n'avoir plus que trois binaires à publier au lieu de
   quatre plus une dylib.
3. **Les sommes de contrôle.** Continuwuity ne publie **aucun** fichier de sommes en amont :
   celles écrites dans l'installeur ont été relevées à la main, une fois. Il faut soit une
   étape de publication qui les relève et les réécrit dans le script (le script et les
   binaires étant publiés ensemble, c'est cohérent), soit un `SHA256SUMS` signé à côté.
   Publier un installeur qui pointe sur une release amont sans somme vérifiable serait pire
   que ce qu'on a aujourd'hui.

---

## Rejouer les preuves

```
# Le Mac
cd ~/correspondance-un-clic
bash infra/relais/tests/install-plan.sh                     # ne touche à rien
cd ~/unclic-publication && python3 -m http.server 8020 --bind 127.0.0.1 &
cd ~/correspondance-un-clic
CORRESPONDANCE_RELEASES=http://127.0.0.1:8020 bash infra/relais/install.sh
launchctl bootout gui/$(id -u)/app.correspondance.relais
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/app.correspondance.relais.plist
xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Debug -derivedDataPath /tmp/dd-unclic build
CORRESPONDANCE_HOME=unclic /tmp/dd-unclic/Build/Products/Debug/Correspondance.app/Contents/MacOS/Correspondance
bash infra/relais/uninstall.sh                              # ne laisse rien

# Le NUC
scp infra/relais/install.sh infra/relais/uninstall.sh nuc:/tmp/
ssh nuc 'bash /tmp/install.sh --prefix $HOME/unclic'
ssh -N -L 8010:127.0.0.1:8010 nuc &                         # puis coller le code dans l'app
ssh nuc 'systemctl --user restart correspondance-relais'
ssh nuc 'bash /tmp/uninstall.sh --prefix $HOME/unclic'
```
