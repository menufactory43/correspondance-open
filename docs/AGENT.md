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
- `claude -p` avec `allowedTools` (Read, Grep, Glob par défaut) — le reste est refusé,
  sauf si `claude.permission.enabled` : l'outil est alors **demandé dans la room**
  (👍 pour autoriser, 👎 pour refuser, refus après `timeoutSeconds`, 120 s par défaut).
  En tête-à-tête la question est un message ordinaire (lisible depuis Element ou le
  téléphone) ; devant des tiers ou un pont, un event `fr.correspondance.agent.permission`
  que les ponts ne relaient pas — la demande ne part jamais vers le réseau.
  Mécanique : `claude` lance `correspondance-agent permission-tool <spool>` en serveur
  MCP (`--permission-prompt-tool mcp__cc-perm__approve`) ; demande et décision
  transitent par fichiers dans le spool, seuls les `owners` tranchent.
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

## Suite prévue

1. Éprouver les permissions sur le NUC (activer `claude.permission.enabled`, un `Bash`
   inoffensif depuis la note à soi, 👍 depuis l'iPhone).
2. Rendre `fr.correspondance.agent.permission` dans l'app (boutons 👍/👎 dans le fil) —
   sans quoi, dans une room avec tiers, la question n'est visible nulle part.
3. Test relais réel (WhatsApp « Vous », puis une room choisie).
4. Éprouver `@hermes` sur le NUC (le backend existe, voir « Multi-moteurs ») ;
   puis `@codex`, `@gem` sur le même contrat `AgentBackend`.
5. Mémoire transversale : ce que cc sait d'un contact, partagé entre ses rooms.

## Multi-moteurs

Un bot = un utilisateur Matrix = un moteur = une instance de `correspondance-agent`.
Le harnais (déclencheur, owners, plafond, direct/brouillon, relais) est le même
pour tous ; seul `backend` change dans la config.

Moteurs disponibles :

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
