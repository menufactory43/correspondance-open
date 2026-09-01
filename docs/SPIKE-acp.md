# Spike — ACP et l'abonnement

Question posée par `docs/PLAN-relais-agents.md` (« la demi-journée ACP × abonnement ») :
**peut-on piloter Claude Code par l'Agent Client Protocol en gardant l'authentification par
abonnement, ou faut-il une clé d'API ?** Et accessoirement : la carte 👍 survit-elle au
changement de couture ?

Éprouvé le 1ᵉʳ septembre 2026 sur macOS 26.6, `claude` 2.1.252, sans `ANTHROPIC_API_KEY`
dans l'environnement (les identifiants d'abonnement vivent dans le Trousseau, entrée
`Claude Code-credentials`).

## Réponse courte

**Oui, l'abonnement suffit — pour les deux adaptateurs.** L'affirmation trouvée en ligne
(« `claude-agent-acp` exige une clé d'API, les jetons OAuth d'un abonnement Max sont
refusés ») est **périmée** : elle décrivait une version antérieure. Testé en 0.70.0, le tour
part et se termine sur l'abonnement (`apiType=native baseUrl=native`).

Et le protocole nous rend tout ce qu'on bricole aujourd'hui : la permission, la reprise, la
réponse progressive, l'annulation, le choix du modèle, le compte des jetons.

## Ce qui a été testé

| Ce qu'on voulait savoir | `@zed-industries/claude-code-acp` 0.16.2 | `@agentclientprotocol/claude-agent-acp` 0.70.0 |
|---|---|---|
| Tour complet sans clé d'API | ✅ `stopReason: end_turn`, a répondu « PONG » | ✅ `end_turn`, `apiType=native` |
| `session/request_permission` | ✅ demandé, trois options (`allow_always`, `allow`, `reject`) | ⚠️ **pas demandé au défaut** — voir le piège |
| Refus honoré | ✅ le fichier n'est pas créé | ✅ une fois le mode forcé |
| 👍 honoré | ✅ le fichier est créé | ✅ |
| `session/load` (reprise) | ✅ mémoire retrouvée dans un **autre processus** | ✅ annoncé (`loadSession: true`) |
| Réponse progressive | ✅ `agent_message_chunk` | ✅ + `tool_call`, `tool_call_update`, `usage_update` |
| Modèles exposés | ✅ `default` (Opus 4.6) · `sonnet` · `haiku` | ✅ |

## Les deux pièges, et ils comptent

**1. Le mode par défaut n'est pas le même, et l'un des deux décide à notre place.**

`claude-code-acp` démarre en mode `default` (« prompts for dangerous operations ») : il nous
demande. `claude-agent-acp` démarre en mode **`auto`** — « *use a model classifier to
approve/deny permission prompts* ». Au premier essai, il a lancé `echo bonjour > preuve2.txt`
**sans jamais nous demander quoi que ce soit**, et le fichier a bien été créé. Un
`session/set_mode` vers `default` rétablit la demande, et le refus est alors honoré.

> **Règle pour le catalogue des moteurs** : le mode de permission se **force explicitement**
> après chaque `session/new`. Ne jamais faire confiance au défaut d'un adaptateur — il change
> d'une version à l'autre, et son défaut peut être « un modèle décide pour toi ».

C'est exactement la table des trois régimes du plan (*contrôlé* / *pré-réglé* / *ouvert*),
mais découverte à l'exécution : un même moteur bascule d'un régime à l'autre selon un champ.
Donc le catalogue ne note pas « ce moteur demande la permission » — il note « ce moteur
demande la permission **dans ce mode**, vérifié à cette version ».

**2. La CLI refuse de se lancer dans une session Claude Code.**

`Error: Claude Code cannot be launched inside another Claude Code session.` L'adaptateur
lance la vraie CLI en dessous ; elle refuse l'imbrication tant que `CLAUDECODE` est dans
l'environnement. Sans conséquence en production (`correspondance-agent` tourne en service,
pas dans Claude Code), mais bloquant pour tester depuis une session Claude Code — et un
signal utile : **c'est bien la CLI, donc bien l'abonnement de la machine.**

## Recommandation

**ACP s'ajoute, puis remplace — dans cet ordre.**

1. `ACPBackend` conforme au contrat `AgentBackend` existant, avec le mode de permission forcé
   au `session/new` et `session/load` pour la mémoire par conversation.
2. `ClaudeCodeBackend` (la CLI en direct) reste là une version, comme filet : la dépendance
   Node/npm sur l'hôte est nouvelle, et elle n'est pas éprouvée sur le NUC.
3. Une fois l'ACP éprouvé sur Linux, `ClaudeCodeBackend` et `HermesBackend` deviennent des
   entrées de catalogue comme les autres — et `codex-acp`, `goose acp` arrivent gratuitement.

Ce que le passage à ACP nous fait gagner, concrètement, sur ce qui est aujourd'hui du code
maison : le parseur de `--output-format stream-json` (→ `session/update`), le serveur MCP de
permissions (→ `session/request_permission`), les sessions `--resume` (→ `session/load`), le
bouton « Arrêter » (→ `session/cancel`), et le plafond horaire qui devient un plafond de
jetons mesuré (→ `usage_update`).

## Ce qui reste à éprouver

- **Sur Linux, en service** : `npx` suppose Node sur l'hôte. Il faudra épingler une version
  de l'adaptateur et la poser à l'installation, pas la chercher au lancement.
- **Le coût du démarrage** : chaque `session/new` relance une CLI. Mesurer, et décider si un
  processus est gardé chaud par conversation ou par agent.
- **Hermes en ACP** : expose-t-il un adaptateur ? Sinon il reste un moteur CLI du catalogue.

## Reproduire

Le harnais est dans `tools/acp-spike/` — trois clients JSON-RPC minimaux, l'équivalent Node
de ce que fera `ACPBackend`. Les versions bougent vite : ces conclusions se re-testent, elles
ne se citent pas.

```bash
mkdir /tmp/acp && cd /tmp/acp && npm init -y
npm install @zed-industries/claude-code-acp @agentclientprotocol/claude-agent-acp
cp <dépôt>/tools/acp-spike/*.mjs .

# 1. un tour sans clé d'API (retire CLAUDECODE de l'environnement)
node drive.mjs "npx --no-install claude-code-acp" "Réponds uniquement le mot PONG."

# 2. la permission : refusée par défaut, accordée avec --allow
node drive.mjs "npx --no-install claude-code-acp" "Lance : echo bonjour > preuve.txt"
node drive.mjs "npx --no-install claude-code-acp" "Lance : echo bonjour > preuve.txt" --allow

# 3. la reprise dans un autre processus
node load.mjs

# 4. le piège du mode « auto » de claude-agent-acp
node mode.mjs
```
