# Agent « cc » — Claude Code dans tes conversations

`@cc` est un utilisateur Matrix du Relais (`@cc:correspondance.local`) piloté par
`correspondance-agent`, qui tourne **24/7 sur le NUC** (systemd utilisateur) et
lance le `claude` de la machine — l'abonnement, jamais de clé API.

## Ce qui marche (testé)

| Chemin | État |
|---|---|
| `@cc …` dans une room où cc est invité → réponse de Claude en citation | ✅ (Note à soi, ~5 s) |
| 24/7 sur le NUC, Mac fermé | ✅ (`systemctl --user status correspondance-agent`) |
| Tête-à-tête (membres ⊆ propriétaires + cc) → réponse **directe** | ✅ |
| Room avec un tiers (joint **ou invité**) → **brouillon** : event `fr.correspondance.agent.proposal`, rien de visible | ✅ |
| Mode relais des ponts (réponse en ton nom, le pont préfixe « 🤖 cc : ») | ✅ testé sur le chat WhatsApp « Vous » : inviter cc, `!wa set-relay`, `@cc …` → réponse relayée en ~5 s |
| Rendu des brouillons dans Correspondance (envoyer / modifier / ignorer) | ✅ |
| Approbations d'outils depuis la conversation (`--permission-prompt-tool`, 👍/👎) | ✅ agent + serveur MCP testés en local — pas encore éprouvé sur le NUC |

## Garde-fous

- Seuls les `owners` déclenchent ; tout autre expéditeur est ignoré en silence.
- L'agent ne rejoint que les rooms où **un propriétaire** l'invite.
- Une demande à la fois par room ; plafond glissant (30/h par défaut).
- **Pleine permission, et trois bornes.** Un agent invité par son propriétaire a ses
  outils : le régime est posé explicitement (`--permission-mode bypassPermissions` sur la
  CLI, `session/set_mode` en ACP) et on répond `allow_always` à toute demande. Ce qui
  borne le risque n'est plus une question posée mais :
  1. **un dossier par room, jamais `~`** — le `cwd` d'un tour est
     `~/Correspondance/<agent>/<room>` tant qu'aucun dépôt n'est lié (`Workspace`) ;
  2. **les propriétaires seuls déclenchent**, et un **fantôme de pont** (`@whatsapp_…`)
     jamais — même inscrit par erreur dans `owners` (`Trigger.isBridgeGhost`) ;
  3. **le journal des tours** dans la room console (`fr.correspondance.agent.journal`) :
     qui, quoi, quels outils, combien de temps.
  Le risque assumé : le prompt contient du texte écrit par d'autres (message cité, fil
  ponté), et avec `Bash` ouvert c'est un chemin d'exécution. La parade est le dossier
  borné, pas une question à laquelle on répondrait oui. Cf. `docs/PLAN-relais-agents.md`.
  Le spool de permissions et `permission-tool` restent en place pour la CLI (`claude.permission.enabled`,
  faux par défaut) ; ils disparaîtront avec le passage complet à l'ACP.
- L'historique n'est jamais rejoué (seuls les messages postérieurs au démarrage comptent).
- Un `join` ne déclenche jamais rien : le déclencheur est un message qui **commence** par `@cc`.

## Architecture

```
Packages/CorrespondanceCore
├── Sources/CorrespondanceMatrixClient   client REST Matrix, Foundation pur (compile Linux)
├── Sources/CorrespondanceAgentKit       config, état, déclencheur, plafond, backend claude, boucle
└── Sources/correspondance-agent         exécutable : init | rooms | run | ask
```

Core réexporte le client (`@_exported`) : l'app et l'iPhone ne voient pas la coupe.
Une session Claude **par room** (`--resume`) : cc a de la mémoire par conversation.
`rooms` de la config associe une room à un dépôt (`cwd`) et force `direct`/`draft`.

## Exploitation

```bash
infra/agent/deploy.sh                        # sources → build Linux (Docker) → binaire → restart
ssh nuc journalctl --user -u correspondance-agent -f
scripts/invite-agent.sh ['!room:…']          # inviter cc (ta session Trousseau), note à soi par défaut
scripts/agent-e2e.sh "question"              # test de bout en bout via la note à soi
```

Config : `~/.correspondance-agent/config.json` (NUC, 0600 — contient le mot de passe
Matrix de cc). État (token, sessions Claude, position de sync) : `state.json` à côté.

## L'hôte « Ce Mac » (phase 2)

L'app embarque l'agent : le binaire dans `Contents/MacOS/correspondance-agent`, son plist
dans `Contents/Library/LaunchAgents/app.correspondance.agent.plist` — `SMAppService` ne le
cherche que là. Un plist est statique : il ne connaît ni `~`, ni les variables de la
session, d'où `--agent cc`, dont le binaire déduit son dossier (`AgentHome`). L'ancien
dossier de `cc` est conservé (`~/.correspondance-agent`) : le NUC ne perd pas son état.

« Activer sur ce Mac » enchaîne, dans cet ordre :

1. **Vérifier le pouvoir** — `GET /_synapse/admin/v1/users/<moi>/admin`. Sans ce pouvoir,
   l'app le dit au lieu d'échouer à mi-chemin.
2. **Créer le compte du bot** — `PUT /_synapse/admin/v2/users/@cc:…` avec un mot de passe
   tiré au hasard, **`logout_devices: false`** : sans lui, poser un mot de passe déconnecte
   toutes les sessions du bot, et un clic ici tuerait l'agent qui tourne sur le NUC. Un
   compte qui existe déjà et dont on a le secret au Trousseau n'est pas retouché.
3. **Poser l'amorce** — `~/.correspondance-agent/config.json` en `0600` (dossier `0700`),
   trois lignes : `homeserver`, `user`, `password`, plus le propriétaire. Le mot de passe
   va aussi au Trousseau (`app.correspondance.agent`), jamais dans une room.
4. **Enregistrer le service** — `SMAppService.agent(plistName:).register()`.
5. **Ouvrir la console** et y écrire la configuration.

### Vérification manuelle — non éprouvée de bout en bout

Tout ce qui précède est éprouvé sauf **l'approbation dans Éléments d'ouverture** : elle
demande une main humaine et une app signée lancée hors Xcode. La procédure exacte :

1. `xcodebuild -project Correspondance.xcodeproj -scheme Correspondance -configuration Release build`,
   puis lancer l'app depuis le Finder (pas depuis Xcode : le service enregistré par une
   app lancée par Xcode porte un chemin de DerivedData qui bougera).
2. Vérifier que l'agent est bien embarqué :
   `ls Correspondance.app/Contents/MacOS/correspondance-agent` et
   `ls Correspondance.app/Contents/Library/LaunchAgents/`.
3. Réglages › Agent › **Sur ce Mac** doit dire « pas installé sur ce Mac », et
   « Activer sur ce Mac » doit être cliquable — s'il est grisé, le compte connecté n'est
   pas administrateur du Relais, et la ligne au-dessous le dit.
4. Cliquer **Activer sur ce Mac**. Attendu : la ligne passe à « actif sur ce Mac », **ou**
   à « à autoriser dans Réglages Système › Éléments d'ouverture » avec un bouton
   « Autoriser… ».
5. Si c'est le second cas : cliquer « Autoriser… » (macOS ouvre
   Réglages Système › Général › Ouverture et extensions › Éléments d'ouverture), activer
   « Correspondance », revenir, cliquer « Rafraîchir ». Attendu : « actif sur ce Mac ».
6. Vérifier que l'agent tourne vraiment :
   `launchctl print gui/$UID/app.correspondance.agent | head -20` et
   `tail -f /tmp/correspondance-agent.log` — on doit y lire « connecté comme @cc:… »
   puis la ligne des moteurs.
7. Depuis l'app, dans la note à soi : `@cc ping`. Attendu : une réponse en moins d'une
   minute, et un tour de plus dans « Derniers tours ».

**Ce qui reste à voir la première fois** : macOS peut exiger l'approbation *après* le
premier `register()` sans le dire ; le plist embarqué doit être signé avec l'app (il l'est,
il fait partie du bundle) ; et une app déplacée dans le Finder après enregistrement peut
faire perdre le service — auquel cas « Désactiver » puis « Activer » le repose.

## La config vient du Relais

Une **room console** par agent porte sa configuration, event d'état
`fr.correspondance.agent.config` (`AgentRemoteConfig`, versionné) : l'agent la lit au
démarrage et la suit à chaque `/sync` — changer un palier d'outils ou un plafond depuis
l'app prend effet sans SSH ni redémarrage. L'agent découvre sa console tout seul : c'est
la room qui porte un event de config à son nom, écrit par un propriétaire.

Sur l'hôte il ne reste que l'**amorce** : `homeserver`, `user`, `password`. Elle est
l'ancre — rien d'écrit dans une room ne change l'identité de l'agent ni son Relais, et
**qui a le droit de le reconfigurer** se lit dans le fichier, pas dans l'event.

Le repli est complet : sans room console, un `config.json` d'hier tourne à l'identique.

## Suite prévue

1. L'app écrit la config dans la room console et la crée à l'activation (côté agent : fait).
2. Hôte « Ce Mac » : `SMAppService`, cible `correspondance-agent` embarquée, création du
   compte bot (`logout_devices: false`).
3. Hôte distant assisté : binaire publié, commande à coller, jeton d'amorce.
4. `correspondance-mcp` : l'inbox comme outil pour un agent du dehors.
5. Ateliers (salons multi-agents) puis chiffrement — cf. `docs/PLAN-relais-agents.md`.

## Multi-moteurs

Un bot = un utilisateur Matrix = un moteur = une instance de `correspondance-agent`.
Le harnais (déclencheur, owners, plafond, direct/brouillon, relais) est le même
pour tous ; seul `backend` change dans la config.

Moteurs disponibles :

- `acp` : **n'importe quel moteur qui parle l'Agent Client Protocol** — `claude-code-acp`
  (défaut), `codex-acp`, `goose acp`. Un moteur de plus est une entrée de config, pas un
  backend de plus : `acp.command`, `acp.arguments`, `acp.permissionModes`. Le protocole
  rend la permission (`session/request_permission`), la reprise (`session/load`), la
  réponse progressive (`session/update`) et le compte des jetons. **L'abonnement suffit**,
  éprouvé — cf. `docs/SPIKE-acp.md`, qui dit aussi pourquoi le mode se force toujours.

  **La dépendance Node, et sa règle.** L'ACP ajoute un adaptateur Node là où `claude`
  suffisait. Trois précautions, et le NUC ne bascule pas avant qu'elles tiennent :
  1. **une version épinglée** dans la config (`acp.pinnedVersion`, `acp.installCommand`) —
     une version qu'on n'a pas éprouvée se signale dans le journal, parce que le régime de
     permission par défaut d'un adaptateur change d'une version à l'autre ;
  2. **l'adaptateur est posé par l'installation** — la cible embarquée pour ce Mac,
     l'installeur pour un hôte distant — jamais cherché au lancement ;
  3. **repli automatique sur `ClaudeCodeBackend`** (`FallbackBackend`) si l'adaptateur
     manque ou ne répond pas : l'agent répond quand même, et le journal le dit. Le repli
     est collant — on ne réessaie pas l'adaptateur à chaque message — et il ne se
     déclenche pas sur un tour trop long, qu'on ne rejoue pas ailleurs.

  **Un moteur chaud par conversation.** Un tour froid paie ~2,9 s de démarrage (0,4 s de
  processus, 2,5 s de `session/load` — mesuré dans `docs/SPIKE-acp.md`). `ACPEnginePool`
  garde donc un moteur debout par dossier de conversation, quatre au plus, éteint après
  dix minutes de silence.
- `claude` (défaut) : Claude Code, `claude -p`, sessions `--resume`, permissions 👍.
- `hermes` : [Hermes de Nous Research](https://hermes-agent.nousresearch.com) —
  `hermes -z` (un tour, texte seul), reprise `-r`, `session_id` lu dans
  `--usage-file`. Sa mémoire persistante (SQLite) vient avec. **Ses outils se
  règlent dans sa propre config (`hermes tools`), pas dans la nôtre** : pas de
  crochet d'approbation, donc le spool de permissions est ignoré — configure-le
  serré avant de l'inviter où que ce soit.

**Où sont les moteurs ?** `correspondance-agent doctor` scanne la machine de
l'agent (chemins habituels, `~/.local/bin` compris — l'installeur d'Hermes pose
son binaire là) et dit si le moteur configuré est prêt. Au démarrage, l'agent
poste le même scan en event `fr.correspondance.agent.status` dans ses rooms en
tête-à-tête — la note à soi en tête — et l'app le montre dans
**Réglages › Agent › Moteurs** (bouton « Scanner »). La présence Matrix aurait
été le canal naturel ; elle est éteinte sur le Relais, exprès.

**Piège Hermes, payé au tir sur cnvsSC/Fauconnier** : en mode `-z`, les flags
de reprise (`--continue` comme `-r`) sont ignorés — chaque tour serait
amnésique. Le backend passe donc par `hermes chat -Q --oneshot -q '…'`, lit le
`session_id` dans la plomberie de `-Q` (stderr), et repart sur une session
neuve quand Hermes répond « No session found ».

Lancer un second bot (exemple `@hermes:correspondance.local`, sur le NUC) :

```bash
# 1. le compte Matrix (une fois, sur le Relais)
docker exec synapse register_new_matrix_user -u hermes -p '…' --no-admin -c /data/homeserver.yaml http://localhost:8008
# 2. sa config : user "hermes", trigger "@hermes", backend "hermes"
CORRESPONDANCE_AGENT_HOME=~/.correspondance-hermes correspondance-agent init
# 3. son service — même binaire, autre HOME
systemctl --user edit --force --full correspondance-hermes   # copie de correspondance-agent + Environment=CORRESPONDANCE_AGENT_HOME=…
```
