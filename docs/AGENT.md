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

## L'hôte « Ce Mac » : cc tourne dans l'app

« Activer sur ce Mac » fait trois choses : créer le compte du bot sur le Relais, poser son
amorce sur le disque, et **lancer l'agent comme processus enfant de l'app**
(`AgentProcessHost`). Il redémarre s'il tombe (palier doublant, 1 s → 60 s, abandon après
huit chutes), il meurt avec l'app, et son journal s'ouvre depuis les réglages.

Le prix est dit dans l'interface, sans détour : **cc s'arrête quand on quitte
Correspondance.** Pour un cc joignable jour et nuit, c'est « Sur une autre machine ».

Le provisionnement, lui, n'a pas changé :

1. **Vérifier le pouvoir** — `GET /_synapse/admin/v1/users/<moi>/admin`. Sans lui, l'app le
   dit au lieu d'échouer à mi-chemin.
2. **Créer le compte du bot** — `PUT /_synapse/admin/v2/users/@cc:…`, mot de passe tiré au
   hasard, **`logout_devices: false`** : sans lui, poser un mot de passe déconnecte toutes
   les sessions du bot, et un clic ici tuerait l'agent qui tourne sur le NUC. Un compte qui
   existe déjà et dont on a le secret au Trousseau n'est pas retouché.
3. **Poser l'amorce** — `~/.correspondance-agent/config.json` en `0600` (dossier `0700`).
   Le mot de passe va aussi au Trousseau (`app.correspondance.agent`), jamais dans une room.
4. **Démarrer**, puis **ouvrir la console** et y écrire la configuration.

### « Actif » est une conclusion, jamais une lecture

Trois choses sont nécessaires : le binaire dans le bundle (**constaté sur le disque**), le
processus vivant, l'amorce présente — et un status récent de l'agent dans sa room console.
Les états intermédiaires ont chacun leur sortie : `.incomplet` (amorce absente) → *Réparer*,
`.silencieux` (rien publié depuis plus d'une heure) → *Arrêter* et le journal, `.abandonne`
(trop de chutes) → *Réparer* et le journal, `.introuvable` (binaire absent) → *Pourquoi ?*.

Cette prudence vient d'un vrai incident : l'app affichait « actif sur ce Mac » sur la foi du
drapeau de `SMAppService`, alors qu'aucun service, aucune amorce et aucun compte n'existaient
— et l'écran ne proposait plus que « Désactiver ». Un écran qui affirme sans vérifier, et
sans laisser de sortie, est pire qu'un écran qui dit « je ne sais pas ».

## Pourquoi cc ne tourne pas en LaunchAgent

`SMAppService` est resté dans le dépôt (`AgentLocalHost.useLaunchAgent`, faux, non proposé
dans l'interface) et son plist aussi. Voici pourquoi on ne s'en sert pas, pour que personne
ne refasse l'enquête.

**Le symptôme.** `SMAppService.agent(plistName: "app.correspondance.agent.plist")` répond
`.notFound` sur la machine d'essai, alors que le plist est bien dans
`Contents/Library/LaunchAgents/` et le binaire dans `Contents/MacOS/`.

**Quatre hypothèses éliminées**, une par une :

| Hypothèse | Comment elle a été écartée |
| --- | --- |
| L'app est lancée par son exécutable, pas par son bundle | relancée avec `open -n` — même résultat |
| L'emplacement (`~/Applications`) | déplacée — même résultat |
| Conflit d'identifiant : cinq bundles partagent `app.correspondance.Correspondance` sur ce Mac, et celui de `/Applications` n'a pas de dossier `LaunchAgents` | rebuild avec `PRODUCT_BUNDLE_IDENTIFIER=…​.essai` — même résultat |
| Plist ou signature invalides | `plutil -lint` OK, `codesign -v --deep --strict` OK, sceau à 19 fichiers |

Le journal unifié ne dit rien : **aucune entrée `smd` ne mentionne l'app**.

**Deux hypothèses restantes, non éprouvées** : le `Label` du plist n'est pas préfixé par
l'identifiant du bundle (`app.correspondance.agent` vs `app.correspondance.Correspondance`),
et la combinaison `BundleProgram` + `ProgramArguments`, qui se recouvrent.

**Pourquoi on s'est arrêté là.** Le LaunchAgent n'achetait qu'une chose : cc qui répond
quand l'app est *quittée* et le Mac allumé. Il ne survit pas au sommeil — l'app le disait
déjà — donc pour un cc joignable à toute heure, la réponse a toujours été l'hôte distant.
Ce bénéfice mince ne valait ni l'approbation dans Éléments d'ouverture, ni quatre états
d'installation, ni un chemin qu'on ne peut pas éprouver depuis Xcode. On a préféré une
chose simple et vérifiable : un processus enfant, surveillé, qui meurt avec l'app.

Si quelqu'un y revient : commencer par renommer le `Label` en
`app.correspondance.Correspondance.agent` et retirer `BundleProgram` ou `ProgramArguments`,
puis regarder `log stream --predicate 'subsystem == "com.apple.smd"'` pendant un
`register()`.

## Au plus un agent vivant par compte

Deux agents sur le même compte Matrix, ce sont **deux réponses à chaque message**. Le plan
le nomme depuis le premier jour ; un essai réel l'a rendu concret : un `pkill` sur l'app a
laissé l'agent vivant et connecté, et relancer l'app donnait deux agents pendant quelques
secondes.

Deux mécaniques le tiennent, et elles se complètent.

### 1. L'agent meurt avec l'app — quelle que soit la façon dont elle meurt

`applicationWillTerminate` ne couvre que la fermeture propre : le seul cas où on n'a besoin
de personne. L'app passe donc son pid à l'agent (`--watch-parent <pid>`), qui vérifie
toutes les deux secondes que son parent n'a pas changé. Quand l'app meurt — proprement, par
un crash, par un « Forcer à quitter » — le noyau réattribue l'agent à `launchd`, il le voit
et s'arrête.

**Pourquoi `getppid()` et pas un tube hérité.** Le tube serait plus immédiat (EOF au lieu
d'un sondage), mais il passerait par l'entrée standard de l'agent — et sous systemd, cette
entrée est `/dev/null`, qui rend EOF *tout de suite* : l'agent s'arrêterait au démarrage sur
le NUC. `getppid()` n'a pas cette ambiguïté, et ne surveille que si on lui a donné un
parent : un agent lancé par systemd n'en a pas, et n'en cherche pas.

Éprouvé pour de vrai : `infra/agent/tests/orphelin.sh <chemin du binaire>` lance un agent
sous un parent, tue le parent par `SIGKILL`, et vérifie que l'agent s'en va tout seul (il
part en une seconde).

### 2. Un second agent refuse de démarrer

L'agent publie son status avec **sa machine et son pid**. Au démarrage, il cherche le status
le plus récent posté sous son compte et tranche :

- **même machine** : le pid est vérifiable (`kill(pid, 0)`). Vivant → il refuse et le dit ;
  mort → c'est son propre cadavre, il démarre. C'est le cas d'un redémarrage après chute, et
  il doit marcher — sinon le surveillant de l'app renoncerait au bout de huit essais.
- **autre machine** : rien n'est vérifiable à distance, alors une fenêtre de deux minutes
  tranche. Plus frais que ça, on croit l'autre vivant.

L'app refuse déjà d'activer un second hôte ; le faire **aussi** dans l'agent couvre le cas
où les deux lanceurs ne se connaissent pas — un `systemctl start` sur le NUC ne sait rien
d'un clic sur le Mac.

### Ce qui reste : le bail

La réponse complète est un **bail court renouvelé dans la room console** : l'agent le prend
au démarrage, le renouvelle en tournant, et un second agent qui trouve un bail valide
s'arrête. C'est l'invariant « au plus une instance vivante » de Buzz, et il a deux mérites
sur ce qui précède — il couvre deux machines sans fenêtre de temps arbitraire, et il expire
tout seul si le porteur meurt.

Il n'est pas fait : plus cher (un event d'état à renouveler, une horloge à ne pas trop
croire) et pas nécessaire tant que les deux mécaniques ci-dessus tiennent les cas réels.
À reprendre le jour où quelqu'un fera tourner deux hôtes pour de bon.

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
