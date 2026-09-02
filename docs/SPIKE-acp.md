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

## Ce qu'un tour coûte (mesuré)

Trois tours froids et deux tours chauds sur la même conversation, `claude-code-acp`
0.16.2, ce Mac. Un tour « froid » relance un processus, comme aujourd'hui ; un tour
« chaud » réutilise un processus et sa session.

| Étape | Froid | Chaud |
|---|---|---|
| processus + `initialize` | 390–454 ms | — (déjà debout) |
| `session/load` (reprendre la conversation) | 2 392–2 459 ms | — (déjà chargée) |
| `session/prompt` (« réponds OK ») | 3 690–4 202 ms | 3 750–11 436 ms |
| **total** | **6,6–7,0 s** | 3,7–11,4 s |

Deux lectures, et la seconde compte plus que la première :

1. **Le démarrage évitable est de ~2,9 s** — 0,4 s de processus, 2,5 s de `session/load`.
   C'est au-dessus de la seconde : on garde donc **un moteur chaud par conversation**,
   avec expiration d'inactivité. Le gain est réel, ~30 % d'un tour courant.
2. **Le temps du modèle domine et varie énormément** (3,7 s à 11,4 s pour la même
   question triviale). Un tour chaud n'est donc pas « deux fois plus rapide » : il est
   plus rapide de 2,9 s, sur un total qui reste dicté par le modèle. Aucun chiffre de
   ce tableau ne doit être cité comme une performance : ce sont des ordres de grandeur,
   pris une fois, sur une machine.

Reproduire : `node tools/acp-spike/mesure.mjs` et `mesure2.mjs`.

## Les autres moteurs, sur l'abonnement — éprouvé le 2 septembre 2026

Même harnais (`tools/acp-spike/drive.mjs`), même question (« réponds PONG »), ce Mac, les
CLI déjà connectées par leur propre `login`, aucune clé d'API dans l'environnement.

| Moteur | Commande | Parle ACP ? | S'authentifie par… | Le tour |
|---|---|---|---|---|
| Codex | `codex-acp` (`@agentclientprotocol/codex-acp` 1.8.0) | ✅ `initialize`, `session/new` (modèles GPT-5.6) | le compte ChatGPT de `codex login`, sans clé | ✗ « You've hit your usage limit. Upgrade to Plus » — c'est le compte, pas le protocole |
| Grok Build | `grok agent stdio` (`grok` 1.0.13) | ✅ `session/new` (grok-4.6) | le compte de `grok login` (SuperGrok / X Premium), sans clé | ✗ `402 Grok Build usage balance exhausted` — le compte, pas le protocole |
| Gemini CLI | `gemini --acp` (0.55.1) | ✅ `initialize` | Google (`oauth-personal`) | ✗ `session/new` : « This client is no longer supported for Gemini Code Assist for individuals. Please migrate to Antigravity » |
| OpenCode | `opencode acp` (1.18.23) | ✅ | son propre compte | ✅ PONG — mais sur `opencode/big-pickle`, son modèle gratuit, pas un abonnement |

Ce que ça décide :

- **Codex et Grok entrent au catalogue.** Le protocole marche et l'authentification est bien
  celle de l'abonnement. Que les deux tours aient échoué sur un quota épuisé est une preuve
  de plus : c'est le compte de la CLI qui paie, pas une clé.
- **Gemini n'entre pas.** Google a fermé Gemini CLI aux comptes personnels au profit
  d'Antigravity ; sans abonnement qui passe, pas d'entrée. À re-tester si Antigravity expose
  un ACP.
- **OpenCode n'entre pas non plus, pour l'instant.** Il répond, mais sur son modèle maison :
  ce n'est pas « ton abonnement », c'est le sien.
- **Une CLI complète a besoin de ses arguments.** `goose`, `gemini`, `grok` seuls ouvrent
  une interface et attendent un clavier ; c'est `goose acp`, `gemini --acp`,
  `grok agent stdio` qui parlent ACP. La console transporte désormais `acpArguments`, et
  l'agent connaît ceux des commandes du catalogue quand l'app ne dit rien
  (`ACPSettings.defaultArguments`).
- **`@zed-industries/claude-code-acp` est renommé** `@agentclientprotocol/claude-agent-acp`
  (avertissement npm à l'installation). L'épingle 0.16.2 reste : le paquet renommé démarre
  en mode `auto` (voir le piège 1), et rien ne presse tant que l'ancien s'installe.

Non éprouvé : le régime de permission de `codex-acp` et de `grok` (leurs modes, ce qu'ils
font au défaut). Avec la décision « pleine permission » du plan ça pèse moins, mais un
premier tour réel se lit dans la console avant d'inviter l'un ou l'autre ailleurs que dans
une note à soi.

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
