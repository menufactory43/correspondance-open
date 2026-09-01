# Plan — Câbler les agents : Relais, salons, chiffrement

Suite de `docs/PLAN-agents.md` (où tourne l'agent, la room console, les phases 0–5).
Ce document répond à trois exigences nouvelles : **un tiers monte son Relais et ses agents,
où il veut, sans administration système** ; **des salons d'agents** ; **le E2EE**.

Le plan précédent tenait le Relais pour acquis, le clair pour acquis, et un agent par
conversation. Le nœud s'est déplacé : ce n'est plus l'agent, c'est le Relais.

---

## Ce qui se fait ailleurs

| Produit | Où vit l'agent | Où vit sa config | Ce qu'on lui vole |
|---|---|---|---|
| **Hermes** (Nous Research) | une instance, une mémoire, N plateformes (Telegram, Signal, WhatsApp, e-mail, Matrix) ; exécution locale, Docker, SSH, Singularity, Modal | variables d'environnement posées par `hermes gateway setup` ; magasin crypto sur disque | la **portée de session** (`MATRIX_SESSION_SCOPE` = room \| thread, une session par utilisateur), les **listes blanches** (`MATRIX_ALLOWED_USERS`, `MATRIX_ALLOWED_ROOMS`), la mention obligatoire en groupe, l'ignorance des **fantômes de ponts** |
| **baibot** (etke.cc) | un bot Matrix, un conteneur, plusieurs fournisseurs derrière | **dans Matrix** : account data du bot, chiffrable ; portées statique / globale / **room-local** | un agent se **crée depuis la conversation** ; un agent de salon n'existe que là |
| **OpenClaw** (adaptateur Matrix) | une instance chez l'utilisateur, un compte bot, un jeton | fichier + variables ; par room : permissions, compétences, prompt système | le **E2EE réel** (Olm/Megolm par le SDK Rust) et les **politiques** de DM et de room (appairage / liste blanche / ouvert / désactivé) |
| **Grok Bot** (xAI) | un ordinateur cloud par bot, persistant, 120 $/mois | conversationnelle : le bot demande ses accès dans le fil | l'**interface iMessage** assumée, les bots qui **se parlent** (chef de cabinet → spécialistes), les **permissions demandées dans la conversation** |
| **Buzz** ([block/buzz](https://github.com/block/buzz), Apache 2.0) | un harnais `buzz-acp` qui écoute le relai et lance des sous-processus d'agent ; N workers pour une seule identité | variables d'environnement + TOML par canal ; l'identité et l'appartenance sont des events signés sur le relai | **tout** : l'ACP comme couture (ci-dessous), le batch par canal, la politique d'auteur à quatre modes, les commandes de contrôle du propriétaire, et l'identité-clé auditable |

### Six leçons de câblage

1. **La config dans le protocole.** baibot met la config *dans Matrix*. C'est la room console de la phase 1 — convergence, donc le pari est bon. Différence : baibot écrit dans son propre account data ; nous écrivons depuis le propriétaire, donc un état de room. Reste juste.
2. **Un agent a une portée.** Global, ou *de ce salon* (dossier, palier d'outils, prompt). À ajouter à `fr.correspondance.agent.config` : une config globale surchargée par un état par room.
3. **Le fil de l'agent n'est pas le fil humain.** Un tour = un thread (MSC3440), avec sa session. Dans une inbox humaine, c'est ce qui empêche un tour de trois minutes de pousser une vraie conversation hors de l'écran.
4. **Les listes blanches d'abord**, et *visibles dans l'app* — pas seulement tenues dans un JSON.
5. **Ignorer les fantômes de ponts** par motif (`@whatsapp_…`) : un fantôme ne déclenche jamais un tour. Règle explicite et testée, pas un effet de bord des owners.
6. **Les agents se parlent — sous laisse** : délégation nommée par un propriétaire, profondeur 1, budget de tours par salon.

---

## Buzz, de près : le même produit, l'autre protocole

Buzz est de Block, en Apache 2.0, et c'est notre voisin le plus proche : « *a workspace where
humans and agents build together, on a relay you own* ». Relais qu'on possède, agents membres
de plein droit, une seule pile auto-hébergée. Deux différences de fond, et elles nous
arrangent toutes les deux.

- **Nostr, pas Matrix.** Tout est un event signé (NIP-01, NIP-42) dans un log immuable :
  messages, revues, étapes de workflow, events git. L'identité *est* une paire de clés ;
  l'appartenance est un event (`kind:13534`). Conséquence heureuse pour nous : **pas de
  ponts**. Buzz est un plan de travail d'équipe, pas une inbox de réseaux. Notre pari Matrix
  — les ponts, donc les conversations qui existent déjà — reste intact.
- **Pas de E2EE.** Le dépôt le dit franchement : « strong opinions, pending code ». Le relai
  stocke les events signés en clair, la recherche et l'audit sont côté relai. Notre chantier
  E est donc un vrai différenciateur, pas un rattrapage.

Ce qu'on leur prend, en revanche, est considérable — et ça tranche une question ouverte.

### ACP : la couture qu'on cherchait

`buzz-acp` ne parle à aucun moteur en particulier. Il lance un **sous-processus qui parle
l'Agent Client Protocol** en JSON-RPC sur stdio (`initialize` → `session/new` → `session/prompt`,
flux `session/update`, `stopReason`), et les moteurs viennent avec leur adaptateur :
`goose acp`, `codex-acp`, `claude-agent-acp`. **ACP est la couture avec le harnais, MCP la
couture avec les outils.**

C'est exactement ce que `AgentBackend` essaie d'être — avec, aujourd'hui, un parseur de
`claude -p --output-format stream-json` d'un côté et le piège d'`hermes -z` de l'autre, payé
au tir. Et ACP apporte plus qu'un format : **`session/request_permission` est une méthode du
protocole**, appelée par l'agent vers le client — on y répond `allow_always` (décision
« pleine permission », plus bas), mais elle reste le point de contrôle si on change d'avis — avec
`session/load` pour la reprise, `session/cancel` pour le bouton « Arrêter », et
`session/update` pour la réponse progressive. Les quatre choses qu'on bricole, dans un
protocole que trois moteurs parlent déjà.

**Correction sur l'abonnement, et elle change la recommandation.** Il y a deux adaptateurs
Claude et ils ne s'authentifient pas pareil : `claude-agent-acp` (Agent SDK) **exige une clé
d'API** — les jetons OAuth d'un abonnement Max sont refusés ; `@zed-industries/claude-code-acp`
(SDK Claude Code) est réputé reprendre la session de `~/.claude`, mais Zed écrit lui-même que
pour rester dans les limites de l'abonnement il faut lancer la CLI officielle plutôt que passer
par ACP. Les sources se contredisent, et la facturation a bougé récemment.

Donc : **ACP ajouté, pas substitué.** `AgentBackend` reste la couture ; ACP en devient
l'implémentation par défaut pour les moteurs qui le parlent, et `ClaudeCodeBackend` (la CLI en
direct) reste le chemin de l'abonnement tant qu'une demi-journée de test n'a pas prouvé le
contraire. Si le test passe, on supprime du code ; s'il échoue, on n'a rien cassé.

### Quatre mécaniques à copier telles quelles

1. **Le batch par canal.** Les events en attente d'un même canal sont fusionnés en **un seul
   tour**. Trois messages pendant que cc réfléchit ne font pas trois tours qui se marchent
   dessus — ils font le prochain. Une requête en vol par portée, comme notre « une demande à
   la fois par room », mais avec la file qui va avec.
2. **La politique d'auteur à quatre modes** : `owner-only` (défaut), `allowlist`, `anyone`,
   `nobody`. Notre `owners` est le premier mode et rien d'autre ; les trois autres sont ce qui
   permet à un agent d'être utile dans un groupe sans être ouvert à tous.
3. **Les commandes du propriétaire** : `!cancel`, `!rotate` (jeter la session, repartir neuf),
   `!shutdown`. Chez nous ce sont des boutons — « Arrêter » dans la bulle du travail en cours,
   « Nouvelle session » dans la fiche du fil — mais le fond est le même, et `!rotate` manque
   cruellement quand une session part en vrille.
4. **La portée de session** `channel` ou `thread`, comme Hermes. Deuxième confirmation
   indépendante : c'est le bon axe de réglage.

Enfin, l'**identité auditable** : chez Buzz un agent est une clé et chaque acte un event signé.
Notre équivalent est un utilisateur Matrix dont l'**appareil est signé par la clé de signature
croisée du propriétaire** (chantier E) et dont chaque tour est journalisé dans la room console.
Même propriété, obtenue autrement — et elle vaut d'être tenue : c'est ce qui distingue « un
agent a fait ça » de « quelque chose a été posté sous ce nom ».

---

## Pourquoi les agents entrent dans l'inbox

La question mérite d'être posée, parce qu'une partie de ce que fait `cc` aujourd'hui serait
mieux dans un terminal. Quatre choses, et elles seules, exigent la room :

1. **Agir devant quelqu'un d'autre.** Le brouillon, le mode relais WhatsApp, l'agent invité
   dans un groupe : tout suppose un membre avec un nom, visible ou délibérément invisible aux
   autres. Un agent branché en MCP agit *comme toi*, en silence — il ne peut être ni présenté,
   ni tenu responsable, ni laissé dans une conversation qui continue sans toi.
2. **Le contexte est déjà là.** Le fil *est* le prompt : pièces jointes, message cité, membres,
   historique. « Demander à cc » sur un message ne demande aucun copier-coller.
3. **L'asynchrone et le téléphone.** Un tour long revient comme un message, la demande de
   permission arrive sur l'écran verrouillé, le 👍 se donne dans le bus. File de travaux,
   notifications et état de lecture sont déjà là.
4. **Une identité qui dure.** `@cc` est mentionnable, invitable, partageable (un foyer, une
   équipe), et chacun de ses actes est signé par son appareil.

**Ce que ça n'apporte pas** : pour coder seul sur sa machine, un agent dans une room est
strictement moins bon qu'un terminal — plus lent, moins pilotable, pas de diff. L'agent dans
l'inbox ne remplace pas Claude Code, et il coûte un utilisateur Matrix, un hôte, un modèle de
permissions et une politique anti-boucle.

**D'où la répartition** : l'agent *dans* l'inbox quand ça concerne d'autres gens, de l'attente
ou le téléphone ; l'inbox *comme outil* quand ça concerne tes messages depuis un établi où tu
es déjà assis. Deux sens du même câblage, pas deux concurrents.

**Et la règle qui domine tout le chantier agents** : *un agent doit vider la file, jamais la
remplir.* L'inbox vaut par le fait qu'elle se vide ; un agent qui poste, propose, journalise et
demande des permissions peut la remplir plus vite qu'on ne la vide. Les tours dans des threads,
le brouillon par défaut, la mention obligatoire, le journal dans la console et pas dans le fil
ne sont pas des détails d'implémentation : c'est ce qui rend la chose supportable.

---

## Étendre sans coder : trois coutures, trois catalogues

L'ambition — « le Claude Desktop de tout le monde, humains et IA » — se juge à une seule
chose : **ajouter un moteur, un outil ou un réseau doit être une donnée, pas du code.** Le
plus dur est déjà fait, parce que les trois coutures existent et qu'aucune n'est à inventer.

| Ce qu'on ajoute | Couture | Ce que ça coûte |
|---|---|---|
| **un moteur** (codex, goose, gemini, le prochain) | ACP — ou la CLI en direct pour les moteurs à abonnement | une entrée dans le catalogue des moteurs |
| **un outil** (ce que l'agent sait faire) | MCP | un serveur MCP déclaré dans la config de l'agent |
| **un réseau** (Discord, Telegram, LinkedIn…) | les ponts Matrix (application services) | un service dans le compose du Relais |

**Le catalogue des moteurs** est la pièce qui manque, et c'est elle qui rend « ajouter un
type d'agent » facile. Un fichier versionné — livré avec l'app, rafraîchissable, surchargé
par la room console — où chaque moteur est une entrée :

```
id, nom affiché, icône
comment le lancer      : commande ACP (ou commande CLI + parseur, pour les moteurs à abonnement)
comment le trouver     : chemins de détection (~/.local/bin, /opt/homebrew/bin, ~/.claude/local)
comment l'installer    : la commande à proposer
comment s'y connecter  : la commande de login, si session interactive
ce qu'il sait faire    : hook de permission ? reprise ? streaming ? annulation ?
palier d'outils par défaut
```

Ajouter `goose` devient une entrée, pas un `AgentBackend`. Et le champ « hook de permission »
n'est pas décoratif : c'est lui qui décide de ce que l'app a le droit de promettre.

### Décision : pleine permission, et ce qui borne vraiment le risque

**Pas de carte 👍.** Un agent invité par son propriétaire a tous ses outils ; on répond
`allow_always` à `session/request_permission` et on force le mode permissif après chaque
`session/new`. La carte de permission sort de la phase 0, et avec elle le spool de fichiers et
le serveur MCP d'approbation.

Ce qui borne le risque n'est de toute façon pas la carte — c'est ce triptyque, et il reste :

1. **Un dossier par room, jamais `~`.** Le `cwd` d'un tour est `~/.correspondance-<agent>/ateliers/<room>`
   tant qu'aucun dépôt n'est lié. C'est le seul vrai rayon d'explosion.
2. **Seuls les propriétaires déclenchent**, et un fantôme de pont ne déclenche jamais.
3. **Le journal des tours** dans la room console : qui, quoi, quels outils, combien de temps.

Le risque assumé, dit franchement : le prompt d'un tour contient du texte écrit par d'autres
(le message cité, un fil ponté). Avec `Bash` ouvert, c'est un chemin d'exécution. La parade
n'est pas une question posée à l'utilisateur — il dirait oui — mais le dossier borné et le
contenu tiers rendu comme **donnée marquée, jamais comme instruction**.

### Ce que les moteurs permettent, et qui varie

Le catalogue doit quand même noter le régime de chaque moteur, non pour demander mais pour
savoir **ce qu'on force** :

| Régime | Ce que ça veut dire | Ce qu'on en fait |
|---|---|---|
| **Contrôlé** | le moteur nous rend la décision (`session/request_permission`) | on répond `allow_always` |
| **Pré-réglé** | les outils sont fixés dans la config du moteur (Hermes) | on le configure serré une fois, avant l'invitation |
| **Ouvert** | aucune limite lisible | à n'inviter que dans une room console |

Et la leçon du spike : **le défaut d'un adaptateur peut être « un modèle décide à ta place »** —
`claude-agent-acp` 0.70.0 démarre en mode `auto` et a exécuté un `Bash` sans rien demander. Le
catalogue ne note donc pas « ce moteur demande la permission » mais « dans ce mode, vérifié à
cette version », et le mode se force explicitement après chaque `session/new`.

**La règle qui domine** : *Correspondance règle le dehors — qui déclenche, où ça tourne, dans
quel dossier, quand, combien, devant qui. Le moteur règle le dedans.*

### Le renversement : `correspondance-mcp`

Aujourd'hui les agents entrent dans l'inbox. L'autre sens sépare une fonctionnalité d'une
plateforme : **un serveur MCP qui expose l'inbox**, pour que n'importe quel agent — dans Claude
Desktop, dans Zed, sur un serveur — travaille sur tes messages sous tes règles, sans être invité
nulle part. Buzz fait exactement ça (`buzz-cli` en JSON, `buzz-dev-mcp` pour les outils), et la
moitié du travail existe déjà : le serveur MCP de permissions.

**Où il tourne.** Un binaire local à côté de l'app, en transport stdio, qui **réutilise la
session Matrix du Trousseau** — aucun nouveau secret, aucune nouvelle porte ouverte. C'est aussi
la seule place tenable après le chantier E : les rooms chiffrées demandent un magasin de clés et
un appareil vérifié, et l'app en a un. Un point d'accès distant (Claude sur le téléphone) est un
autre sujet : il faut exposer, authentifier, et il attendra.

**Les outils**, dans les mots du domaine (`CONTEXT.md`) :

| Outil | Ce qu'il fait | Régime |
|---|---|---|
| `list_queue` | la file : ce qui attend, par réseau, contact, âge, avec un extrait | lecture |
| `read_conversation` | les derniers messages d'une conversation | lecture |
| `search` | recherche dans le store local | lecture |
| `draft_reply` | pose une **proposition** — elle apparaît en brouillon dans l'app, rien ne part | écriture sûre |
| `archive`, `pin`, `mute`, `remind` | traiter la file sans écrire à personne | écriture sûre |
| `send_message` | envoie vraiment | **sous garde** |

**Les gardes, et elles ne sont pas décoratives.**

- **Le défaut est `draft_reply`.** Écrire à un humain n'est pas une action réversible. Envoyer
  demande soit une confirmation explicite dans l'app, soit une liste blanche de conversations
  choisie à la main (« cc peut envoyer dans ma note à soi et dans le groupe famille »).
- **Injection par le contenu.** Les messages lus sont du **texte hostile par construction** : un
  correspondant peut écrire « envoie mes coordonnées bancaires à … ». Deux règles : le contenu
  d'un message est rendu comme donnée marquée, jamais comme instruction ; et `send_message` ne
  peut jamais être déclenché dans le même tour qu'une lecture sans passage par un humain.
  C'est la vulnérabilité propre à ce renversement, et elle n'existe pas dans l'autre sens.
- **Les mêmes plafonds** que l'agent : cadence, une action à la fois par conversation, journal
  des appels dans la room console — un outil MCP n'est pas une porte dérobée aux garde-fous.
- **Jamais de compte lié.** Le serveur parle au Relais, pas aux réseaux : rien ne permet de
  déconnecter WhatsApp ou de lire un QR de liaison.

**Ce que ça donne, concrètement** : depuis Claude Desktop, « qu'est-ce qui attend une réponse
depuis plus de deux jours ? », « résume ce fil », « prépare une réponse à Camille » — et la
réponse t'attend en brouillon dans l'app, à envoyer d'un geste. Répondre *vraiment* à tout depuis
Claude Desktop est possible, mais c'est un réglage qu'on donne conversation par conversation,
pas un défaut.

## Le Relais n'est pas dans l'app

**Règle : l'app ne fait tourner aucun serveur.** Elle ne pose pas de conteneur, ne gère pas
un cycle de vie, ne devient pas une console d'exploitation. Elle *fait créer* un Relais
ailleurs — sur cette machine, sur une autre, ou chez un hébergeur — puis elle s'y appaire.
Trois raisons, et chacune suffirait :

- **ADR 0001.** Le Relais est la source de vérité ; un client ne peut pas héberger la vérité
  dont il dépend, sinon désinstaller l'app efface les conversations.
- **Le Mac dort.** Un Relais qui s'endort avec l'app, c'est un iPhone qui ne reçoit rien et
  des ponts qui se déconnectent. Où vit le Relais est une décision de l'utilisateur, pas un
  effet de bord de l'endroit où il a installé l'app.
- **La distribution.** Une app qui installe un moteur de conteneurs et lance des serveurs
  n'est ni signable proprement, ni explicable à quelqu'un qui la découvre.

### L'écran d'accueil : trois cartes, une seule fin

Le premier lancement pose la question, une fois, en clair — et les trois chemins se
terminent tous par le même **code d'appairage** (QR + six mots, usage unique, périmé en dix
minutes) : l'app en tire l'URL du Relais, le compte propriétaire et le pouvoir d'administrer.
Le « un clic », ce n'est pas l'absence de terminal : c'est l'absence de *recopie* et
l'absence de *choix techniques*.

| Carte | Ce que l'utilisateur fait | Ce qu'on lui dit, franchement |
|---|---|---|
| **J'ai déjà un Relais** | scanner le QR ou coller les six mots | — |
| **Créer un Relais** | choisir la machine, coller **une** commande dans un terminal (`curl -fsSL relais.correspondance.app \| sh`), revenir avec le code | « Sur ce Mac : ton iPhone ne recevra rien quand il dort. Sur une machine allumée : tout marche partout. » |
| **Un Relais hébergé** | un compte ; le code arrive par e-mail | « Tes conversations pontées transitent par nos serveurs. » (grisé tant que la question 1 n'est pas tranchée) |

La deuxième carte est le cœur : **un seul installeur, trois endroits**. Ce Mac, un NUC, un
VPS — c'est la même commande, elle détecte l'hôte, pose ce qu'il faut (moteur de conteneurs
compris, et c'est *son* problème, plus celui de l'app), crée le compte propriétaire et
affiche le code. `infra/matrix/bootstrap.sh` devient cet installeur, publié en release.

**Le Relais reste Synapse.** Les serveurs mono-binaire (Continuwuity, Conduit) sont bien
plus doux à installer mais ne prennent pas les *application services* : pas de ponts, donc
pas d'inbox.

**Réseau** : le tailnet reste le défaut (`http://100.x.y.z:8008`) — c'est ce qui évite
d'ouvrir un port ou de gérer un certificat. L'installeur pose Tailscale s'il manque et met
l'adresse du tailnet dans le code d'appairage.

### Ce que l'app garde, et ce qu'elle ne prend jamais

- **Elle garde** une fiche Relais dans les réglages : adresse, version, santé, place disque,
  ponts connectés. En lecture, alimentée par un point de santé et l'API admin.
- **Elle garde** l'onboarding des ponts — le QR WhatsApp, le lien Signal, la session
  Instagram — piloté depuis « Ajouter un compte », pas en tapant `!wa login` à un bot dans
  Element. **C'est là qu'est le vrai travail de « clé en main »**, plus que dans
  l'installation du serveur : lier ses réseaux est irréductible, mais ça n'a aucune raison
  de ressembler à de l'administration système.
- **Elle ne prend jamais** : démarrer ou arrêter des conteneurs, mettre à jour Synapse,
  éditer un `homeserver.yaml`. La mise à jour appartient à l'installeur
  (`correspondance-relais update`, ou automatique).

---

## Récupérer les abonnements, sans clé

La règle fondatrice tient : **quand il y a un abonnement, jamais de clé.** Ce qui manque,
c'est l'assistance ; `doctor` scanne déjà, il faut qu'il *propose*.

- **Absent** → l'app affiche l'installation exacte pour cet hôte (`npm i -g @anthropic-ai/claude-code`, l'installeur d'Hermes qui pose son binaire dans `~/.local/bin`) et sait la lancer elle-même quand l'hôte est ce Mac.
- **Présent, pas connecté** → seul moment où un terminal est inévitable (session interactive). Sur ce Mac, l'app ouvre Terminal sur `claude login` et attend que le scan repasse au vert ; sur un hôte distant, elle affiche la commande à coller.
- **Prêt** → « Activer » ; le compte du bot est créé dans la foulée (`logout_devices: false`).
- **Le moteur API** reste le seul sans session interactive, donc le seul viable dans le conteneur du Relais. Plafond de jetons par jour, affiché.

Le `PATH` vide d'un LaunchAgent vaut aussi pour le scan : la découverte des moteurs doit
être la nôtre (`~/.local/bin`, `/opt/homebrew/bin`, `~/.claude/local`), jamais `which`.

---

## Salons d'agents

| Forme | Membres | Déclencheur | À quoi ça sert |
|---|---|---|---|
| **Console** | toi + un bot | l'app (events d'état) | config, status, journal, mémoire (phase 1) |
| **Tête-à-tête** | toi + un bot | tout message | parler à cc comme à un correspondant |
| **Atelier** | toi + N bots (+ des humains) | mention seulement | un sujet, plusieurs moteurs |

L'atelier est le seul nouveau, et il n'est dangereux que par ses boucles. Quatre règles :

1. **Mention obligatoire** : aucun agent ne répond à un message qui ne le nomme pas.
2. **Un agent ne déclenche pas un agent**, sauf délégation nommée par un propriétaire, profondeur 1, budget de tours par salon et par heure en plus du plafond par agent.
3. **Un thread par tour** : le travail se déroule dans le thread, seul le résultat remonte.
4. **Portée de salon** : dossier, palier d'outils, prompt — un état de room qui surcharge la config globale de chaque agent.

Un salon d'agents reste une conversation : ce que les agents s'y disent doit se lire, pas
se deviner dans un journal.

---

## E2EE

Le chiffrement n'est pas un module : c'est une propriété qui traverse l'app, l'agent, les
notifications et la recherche. Le point qu'on oublie : **les conversations pontées ne
seront jamais chiffrées de bout en bout honnêtement** — le pont détient les clés du réseau
distant, il est un déchiffreur par construction. Le E2EE protège le *natif* (rooms Matrix,
note à soi, consoles, ateliers) contre l'hébergeur du Relais. C'est exactement le cas
« on héberge le Relais pour quelqu'un ».

| Chemin | Ce que ça demande | Verdict |
|---|---|---|
| **Pantalaimon** | un démon proxy E2EE devant l'agent ; zéro ligne de Swift | ⚠️ repli |
| **matrix-rust-sdk-crypto (FFI)** | la machine à états crypto d'Element, sans E/S réseau, liée en Swift par uniffi ; l'app *et* l'agent partagent le module | ✅ cible |
| **Rien** | le Relais lit tout ; acceptable tant que le Relais est ta machine | — aujourd'hui |

**Une seule pièce crypto, partagée.** `CorrespondanceMatrixClient` est du Foundation pur
qui compile sur Linux ; un module `CorrespondanceCrypto` enveloppant `matrix-sdk-crypto-ffi`
garde cette propriété (Rust compile des deux côtés) et sert iOS, Mac et l'agent.

**La vérification, sans écran.** Un agent doit être un *appareil* vérifié, sinon chaque room
chiffrée affiche un bouclier rouge. Au provisionnement, l'app connaît le mot de passe du bot
puisqu'elle vient de le créer : elle ouvre une session pour lui, pose ses clés, les signe
avec la clé de signature croisée du propriétaire, puis passe le jeton et le magasin à
l'agent. L'agent naît vérifié ; personne ne compare d'émojis.

**Ce que ça casse, et qu'il faut prévoir** : les notifications (`CorrespondanceiOSNotificationService`
devra déchiffrer, donc accéder au magasin par un groupe d'app) ; la recherche (locale, sur
le store local — ce que `PLAN-store-local.md` prépare) ; l'historique (sauvegarde des clés
côté serveur, à activer dès le premier jour) ; le mode brouillon (l'event `proposal` chiffré
reste lisible par l'app — même appareil).

---

## La carte des chantiers

Les phases 0–5 de `PLAN-agents.md` tiennent. Trois chantiers s'y greffent ; l'ordre est
celui de la valeur pour un tiers.

### R — Créer un Relais, puis s'y appairer (4–5 jours)
- **Écran d'accueil** à trois cartes : j'ai déjà un Relais / en créer un / hébergé (grisé).
- `bootstrap.sh` devient un **installeur publié en release**, une commande, trois hôtes (ce Mac, Linux, VPS) : il pose ses dépendances lui-même, crée le compte propriétaire, pose Tailscale s'il manque, et finit sur un **code d'appairage** (QR + six mots, usage unique, dix minutes).
- Dans l'app : scanner / coller → vérification admin → premier `/sync` → fiche Relais en lecture (adresse, version, santé, ponts).
- **Onboarding des ponts** dans « Ajouter un compte » : l'app pilote la room du bot de pont et rend le QR WhatsApp, le lien Signal, la session Instagram. Plus jamais de `!wa login` dans Element.
- **Sortie** : quelqu'un qui n'a jamais ouvert un terminal colle une commande, scanne un QR, lie WhatsApp, et voit sa file.

### A — Les agents, comme prévu (phases 0–4 existantes)
- Room console, hôte « Ce Mac » en un clic, hôte distant assisté, moteur API — et `ACPBackend` à la place du parseur `stream-json`.
- Ajouts issus de la recherche : **portée par room**, **filtre des fantômes de ponts**, **politique d'auteur à quatre modes visible dans l'app**, **un thread par tour**, **file et batch par room**, **« Arrêter » et « Nouvelle session »**.
- Bascule **ACP** d'`AgentBackend` (après la vérification `claude-agent-acp` × abonnement), qui rend `codex` et `goose` gratuits.

### S — Ateliers (2–3 jours)
- Créer un salon avec plusieurs agents depuis l'app ; mention obligatoire ; budget de tours par salon.
- Délégation nommée, profondeur 1, tracée dans la console de chaque agent.
- Rendu : le thread d'un tour se replie dans le fil ; le résultat seul reste visible.

### M — L'inbox comme outil (2–3 jours)
- `correspondance-mcp` : binaire local, transport stdio, session du Trousseau réutilisée ; outils de lecture, de traitement de file et `draft_reply` ; `send_message` derrière une liste blanche par conversation.
- Contenu des messages marqué comme donnée non fiable ; pas d'envoi dans le même tour qu'une lecture ; journal des appels dans la room console.
- Catalogue des moteurs versionné, et « Ajouter un moteur » qui n'est qu'un formulaire.
- **Sortie** : depuis Claude Desktop, « qu'est-ce qui attend une réponse depuis deux jours ? » répond juste, et « prépare une réponse à Camille » laisse un brouillon dans l'app.

### E — Chiffrement (5–8 jours)
- `CorrespondanceCrypto` (uniffi) ; sauvegarde des clés activée d'emblée ; l'extension de notification déchiffre.
- L'agent naît vérifié (clés posées et signées par l'app au provisionnement).
- Chiffrement par défaut des rooms *natives*. Les portails de ponts restent en clair, **et l'app le dit** — un cadenas qui ment est pire que pas de cadenas.

---

## À trancher

1. **Héberger, ou pas ?** Les trois portes couvrent « local » et « distant chez lui ». « Distant chez toi » (multi-tenant Synapse + ponts, facturation, sessions WhatsApp qui expirent) est un métier, pas une phase. Concevoir le code d'appairage maintenant pour que la porte existe ; ne pas l'ouvrir avant dix utilisateurs sur les deux premières.
2. **Le E2EE avant ou après les ateliers ?** Après, si le Relais reste chez chacun. Avant, si tu héberges — et alors c'est la première ligne du plan.
3. **La demi-journée ACP × abonnement.** `claude-agent-acp` exige une clé ; `claude-code-acp` prétend reprendre la session de `~/.claude` ; Zed conseille la CLI pour garder les limites de l'abonnement. À éprouver, pas à lire. Le résultat décide si ACP remplace `ClaudeCodeBackend` ou s'y ajoute — et rien d'autre dans le plan n'en dépend.
4. **Hermes en CLI, en ACP, ou en pair ?** Hermes a sa propre passerelle Matrix *et* trois chemins d'intégration à Buzz. Trois options, donc : l'appeler en CLI (`HermesBackend` d'aujourd'hui), le lancer en ACP s'il l'expose, ou le laisser se connecter seul au Relais et ne faire que l'inviter — moins de code, et ses outils se règlent chez lui.
4. **La mention dans un tête-à-tête.** Taper `@cc` dans un fil qui ne contient que cc est une friction que Grok Bot n'a pas. La supprimer en tête-à-tête, la garder ailleurs ?

---

## Sources

Hermes — [intégration Matrix](https://hermes-agent.ai/integrations/matrix), [présentation](https://hermes-agent.nousresearch.com) ·
baibot — [agents](https://github.com/etkecc/baibot/blob/main/docs/agents.md), [dépôt](https://github.com/etkecc/baibot) ·
OpenClaw — [adaptateur Matrix](https://team400.ai/blog/2026-03-openclaw-matrix-channel-setup-guide) ·
Grok Bot — [VentureBeat](https://venturebeat.com/orchestration/spacexais-grok-bot-turns-agents-into-persistent-digital-coworkers-that-can-operate-your-apps-for-120-per-month), [Composio](https://composio.dev/content/guide-to-frok-bot) ·
[Pantalaimon](https://github.com/matrix-org/pantalaimon) · [matrix-sdk-crypto-ffi](https://matrix-org.github.io/matrix-rust-sdk/matrix_sdk_crypto_ffi/index.html) ·
[Synapse vs Continuwuity](https://www.pistack.xyz/posts/2026-05-02-synapse-vs-dendrite-vs-continuwuity-self-hosted-matrix-server-guide/) ·
Buzz — [dépôt](https://github.com/block/buzz), [harnais ACP](https://github.com/block/buzz/blob/main/crates/buzz-acp/README.md), [site](https://buzz.xyz/)
