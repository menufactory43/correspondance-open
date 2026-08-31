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
| Rendu des brouillons dans Correspondance | ❌ pas encore — l'app ignore `agent.proposal` |
| Approbations d'outils depuis la conversation (`--permission-prompt-tool`) | ❌ pas encore — `allowedTools` en liste blanche en attendant |

## Garde-fous

- Seuls les `owners` déclenchent ; tout autre expéditeur est ignoré en silence.
- L'agent ne rejoint que les rooms où **un propriétaire** l'invite.
- Une demande à la fois par room ; plafond glissant (30/h par défaut).
- `claude -p` avec `allowedTools` (Read, Grep, Glob par défaut) — le reste est refusé.
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

1. Rendu des propositions dans l'app (brouillon pré-rempli dans le composer, « envoyer » = ta voix).
2. Test relais réel (WhatsApp « Vous », puis une room choisie).
3. `--permission-prompt-tool` : approuver un outil par réaction 👍 depuis n'importe où.
4. Multi-moteurs (`@codex`, `@gem`) sur le même contrat `AgentBackend`.
