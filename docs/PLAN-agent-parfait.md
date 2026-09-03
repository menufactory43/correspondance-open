# Plan — L'agent parfait : ce qu'il manque pour tenir les promesses

> État de départ (2026-09-03) : cc répond quand on le nomme, propose un brouillon devant un tiers,
> lit une photo ou un PDF qu'on lui envoie, tourne 24/7 sur le Relais. **Il ne rejoue jamais
> l'historique** (`docs/AGENT.md` § Garde-fous) et ne voit que les messages qui lui sont adressés.
> Conséquence : il ne sait ni résumer un fil, ni traduire ce qu'on reçoit, ni retrouver un montant,
> ni proposer une réponse sans qu'on le lui demande. Le site a été ramené à ça le même jour.

## Ce que font les autres, et où est notre place

| Produit | Ce qu'il fait ou annonce | Ce qu'il n'a pas |
|---|---|---|
| **Beeper** (Automattic) | Feuille de route « BeepMate » : résumé des non-lus, classement urgent / pas urgent, réponses automatiques, traitement local ou cloud au choix ; ouverture des données de chat à Claude ou ChatGPT sur autorisation. Résumé et traduction déjà en bêta. | Pas d'agent qui *agit* (outils, fichiers, machine). Les messages passent par leurs serveurs sauf en mode local. |
| **Franz 6** | Assistant intégré : rattrapage multi-apps, triage, transcription des vocaux, extraction d'actions, brouillons. Local ou cloud UE zéro rétention. | Des webviews, pas des clients natifs : pas d'inbox unifiée réelle, pas d'iPhone. |
| **Rambox** | Assistant Gemini : brouillons, résumés, recherche. | Idem, agrégateur de webviews. |
| **WhatsApp / Apple** | Réponses suggérées à partir du contexte du fil (Writing Help, Apple Intelligence). | Un réseau à la fois. Rien qui traverse Signal, iMessage et Instagram. |
| **OpenAI × Apple Messages** | ChatGPT lit, cherche, rédige et envoie dans iMessage sur Mac. | iMessage seulement. Pas chez vous. |
| **Ferdium** | Rien. Franz 5 gelé. | |

Tout le monde converge vers le même trio : **résumer, proposer une réponse, traduire.** C'est
la table de base. Personne ne fait la suite : un assistant qui est **un contact**, qui **agit**
(fichiers, calendrier, machine, outils), qui a **une mémoire des personnes** à travers cinq
réseaux, et qui **tourne chez l'utilisateur** avec son abonnement. C'est là qu'on est seuls, et
c'est là qu'on doit aller — mais pas avant d'avoir la table de base, sinon on se compare mal.

## Le principe qui commande tout : lire avant de parler

Presque tout ce qui manque tient à une seule chose : l'agent ne voit pas le fil. Donner à un tour
le contexte de la room (les N derniers messages, via `/messages` Matrix, ou la base locale de
l'app pour iMessage) débloque le résumé, la traduction, la recherche, la réponse proposée, la
mémoire. C'est le chantier 0, et tout le reste s'y appuie.

Le risque qu'il ouvre est connu (`AGENT.md` § Garde-fous) : le fil contient du texte écrit par
d'autres, et l'agent a `Bash`. Les parades restent les mêmes — dossier borné par room, journal
des tours, jamais d'envoi sans le propriétaire — et une de plus : **le contexte est marqué comme
donnée**, encadré et attribué (« Camille a écrit : … »), jamais fondu au prompt.

## Vérification d'architecture : un seul assistant, deux moteurs

Beeper range ses fonctions IA en trois cartes : *Langues de traduction*, *Transcription vocale*
(Whisper d'OpenAI, « enverra des clips audio à OpenAI via nos serveurs »), *Mentions IA* (« enverra
les 20 messages les plus récents »). Chacune derrière un abonnement Plus. C'est la bonne liste et la
bonne honnêteté ; ce n'est pas la bonne forme pour nous, et voici pourquoi.

**Deux natures de travail, qu'il ne faut pas confondre.**

| | Réflexes | Tours |
|---|---|---|
| Exemples | traduire ce qui arrive, transcrire un vocal, détecter la langue | résumer, proposer une réponse, répondre seul, agir, se souvenir |
| Quand | à chaque message, sans qu'on demande | quand on le nomme, qu'on réagit, qu'un déclencheur sonne |
| Délai acceptable | < 1 s | 5–30 s |
| Où | sur l'appareil (Apple Translation, `SFSpeechRecognizer`), Relais en option (whisper.cpp) | le moteur de l'agent, sur le Relais ou « Ce Mac », avec l'abonnement |
| Coût | nul | l'abonnement du propriétaire |
| Jugement | aucun, résultat prévisible | tout |

Faire passer un réflexe par un tour d'agent (traduire chaque bulle en appelant Claude) serait lent,
coûteux en quota, et imprévisible. Faire un tour avec un réflexe (résumer avec un modèle local
minuscule) donnerait de la bouillie. Les chantiers 3 et 4 sont donc bien des réflexes côté app, les
autres des tours : le plan est cohérent, on le garde.

**Mais un seul nom, une seule fiche.** Pour l'utilisateur, tout ça c'est cc. On ne présente pas
« Traduction » à côté d'« Assistant » comme deux produits ; on présente **un assistant qui a des
réflexes et qui réfléchit quand on lui parle**. Concrètement, la fiche de cc (niveau 2, racine de
l'héritage du chantier 8b) ressemble à ça :

```
cc                                                   ● en ligne · Ce Mac

Réflexes
  Traduire ce qui arrive            [ Portugais, Anglais ▾ ]    Sur cet appareil
  Traduire ce que j'envoie           ○                            Sur cet appareil
  Transcrire les vocaux              ●                            Sur cet appareil
                                                                  ↳ ou sur votre Relais (whisper), pour la recherche

Quand on lui parle
  Contexte donné à cc                [ 50 derniers messages ▾ ]  Via votre Relais → Anthropic, avec votre abonnement
  Dans les conversations             Sur demande ▾  (par défaut ; chaque fil peut changer)
  Point du matin                     ○  8h00                       Visible par vous seul

Ce qu'il sait de vos contacts       12 fiches ›                   Sur votre Relais, chiffré
Réglages avancés                    ›                             Le fichier, en formulaire
```

Chaque ligne porte **où vont les données** — sur cet appareil, sur votre Relais, chez Anthropic via
votre abonnement. C'est la ligne de Beeper (« enverra … via nos serveurs ») retournée à notre
avantage : rien ne passe par nous, et on le dit à l'endroit exact où on décide.

**Ce que ça règle pour les cas d'usage.**
- *Grand public, famille* : réflexes allumés, cc sur demande. Rien à comprendre.
- *Vendeur, indépendant* : la carte du fil passe en *Propose* ou *Répond seul* avec un modèle.
- *Pro, Slack* : persona par réseau, formulaire du niveau 3, MCP vers ses outils.
- *« Un Grok, un bot à qui parler »* : le fil de cc, déjà là ; le contexte du chantier 0 le rend utile.
- *« Comme Beeper »* : traduction, transcription, mentions avec contexte — les trois y sont, sans
  abonnement Plus et sans passer par des serveurs à nous.

**Ce qu'on ne fait pas, délibérément** : plusieurs agents-produits (« Traducteur », « Résumeur »,
« Vendeur ») comme identités séparées. Buzz le fait parce qu'une équipe de développeurs veut des
rôles ; une personne veut *un* assistant qu'elle règle. Les personas restent des réglages de cc,
pas des contacts. Le multi-moteur (hermes, claude) demeure, en réglages avancés.

**Deux limites à écrire noir sur blanc** : iMessage n'existe que sur le Mac, donc les tours qui
lisent un fil iMessage exigent que le Mac soit allumé, ou qu'il ait poussé le fil au Relais ; et les
réflexes sur l'appareil ne bénéficient pas à la recherche tant que le Relais ne les a pas faits une
fois — d'où l'option whisper sur le Relais, éteinte par défaut.

## Les chantiers

Chaque chantier est décrit par ce que l'utilisateur voit, ce qu'il faut construire, et sa taille.
Ils sont indépendants sauf mention, et l'ordre recommandé est en fin de document.

### 0. Le contexte du fil (2–3 jours) — fondation

- **Vu** : rien de nouveau à l'écran. Mais « @cc c'est quoi cette histoire de plombier ? » répond juste.
- **À construire** : à chaque tour, `correspondance-agent` charge les N derniers messages de la room
  (défaut 50, borné en tokens), les attribue et les horodate, et les place dans le prompt comme
  bloc de données. Pièces jointes : nom et type seulement, téléchargement à la demande. Pour les
  rooms chiffrées (chantier E de `PLAN-relais-agents.md`), le déchiffrement est celui de l'agent.
- **Réglage** : `rooms.<id>.context` (0 pour couper, par défaut 50) dans la room console.

### 1. Rattrapage et résumé (2 jours)

- **Vu** : un bouton **Résumer** en tête de fil quand il y a plus de ~15 non-lus. Dans l'inbox,
  **« Qu'est-ce que j'ai raté ? »** : une carte, tous réseaux confondus, qui liste ce qui attend
  une réponse et ce qui est juste du bruit. Résultat visible par soi seul (même event que les
  brouillons, `fr.correspondance.agent.proposal`, kind `summary`).
- **À construire** : un tour spécial déclenché par l'app, pas par un message — l'agent reçoit une
  instruction et le contexte, répond dans un event privé. Pour l'inbox entière : l'agent parcourt
  les rooms non lues du propriétaire (il est déjà membre de celles où on l'a invité ; pour les
  autres, voir chantier 9).
- C'est la parité Beeper / Franz. Dépend de 0.

### 2. La réponse proposée sans qu'on la demande (2–3 jours)

- **Vu** : dans un fil où on a **activé** l'assistant (opt-in par conversation, éteint par défaut),
  chaque message entrant fait apparaître un brouillon discret sous la zone de saisie. Un geste
  pour l'envoyer, un pour l'ouvrir et le corriger, rien pour l'ignorer. Sur iPhone, dans la
  notification : « Répondre avec cc ».
- **À construire** : le mode existe (brouillon devant un tiers). Ce qui manque : le déclenchement
  sur message entrant sans mention, un délai d'attente (ne pas proposer pendant qu'on tape), le
  rendu compact, et une politique par room (`rooms.<id>.suggest: off | ask | always`).
- **Ce qui nous distingue** de WhatsApp et d'Apple : le même assistant sur les cinq réseaux, qui
  connaît la personne (chantier 5) et peut vérifier quelque chose avant de proposer (calendrier,
  fichier, web). Dépend de 0.

### 3. Traduction (2 jours)

- **Vu** : une bulle en langue étrangère porte un petit **Traduire** ; une fois choisi pour un fil,
  tout ce qui arrive est traduit en dessous, en gris. À l'envoi : « Traduire en anglais avant
  d'envoyer », avec l'original visible pour vérifier.
- **À construire** : un tour sans mémoire, court, avec l'instruction et le texte. Détection de langue
  côté app (`NLLanguageRecognizer`), cache par event pour ne pas retraduire. Sur iPhone, Apple
  Translation on-device en premier choix quand la paire est disponible, l'agent sinon.
- Indépendant de 0.

### 4. Vocaux transcrits (1–2 jours)

- **Vu** : sous chaque message vocal reçu, le texte. Recherchable.
- **À construire** : `SFSpeechRecognizer` sur l'appareil (Mac et iPhone), fallback Whisper sur le
  Relais si le propriétaire l'active. Stocké comme event privé lié au vocal. Franz le fait ; les
  35–50 ans reçoivent beaucoup de vocaux qu'ils n'ont pas envie d'écouter en réunion.
- Indépendant.

### 5. Mémoire par correspondant (3 jours) — le vrai différenciateur

- **Vu** : « Camille est végétarienne depuis mars », « Noé, c'est le plombier, devis en attente »,
  « la belle-famille préfère l'anglais ». L'assistant s'en sert dans ses brouillons sans qu'on le
  répète. Une fiche par personne, lisible et éditable dans l'app (onglet **Ce que cc sait**), avec
  un bouton **Oublier**.
- **À construire** : `PLAN-agents.md` Q7 le décrit déjà — un fichier de mémoire par correspondant,
  event d'état dans la room console, injecté dans le prompt système du tour. Ajouter : l'écriture
  (l'agent propose une note, elle n'est retenue qu'après un tour ; ou le propriétaire écrit lui-même),
  la fusion avec les fils fusionnés (`MergedContact`), et l'affichage.
- Dépend de 0 pour être alimentée automatiquement ; utile seule dès l'écriture manuelle.

### 6. Réponse progressive et travaux longs (2 jours)

- **Vu** : la réponse s'écrit sous nos yeux au lieu de tomber d'un bloc après vingt secondes. Une
  tâche longue (« trie les photos du dossier ») affiche un état, et l'agent revient quand c'est fini.
- **À construire** : déjà prévu (`AGENT.md` § Suite prévue, 6) : `ACP.swift` lit les
  `agent_message_chunk`, il manque le chemin des morceaux dans `AgentBackend.run` et l'édition
  du message Matrix au fil de l'eau (`m.replace`).
- Indépendant.

### 7. Agir dans le monde : calendrier, rappels, fichiers (3–4 jours)

- **Vu** : « @cc mets le dîner de samedi dans le calendrier » → il propose l'événement, 👍 et c'est
  fait. « Rappelle-moi jeudi de relancer Noé si le devis n'est pas arrivé » → jeudi, un message de cc
  dans le fil de Noé, visible par vous seul, avec la réponse déjà prête. « Envoie-moi le PDF du
  devis » → il le retrouve dans le fil et le pose dans la conversation.
- **À construire** : des outils MCP côté app ou côté Relais — `calendar.create` (EventKit, sur
  l'hôte « Ce Mac » ou via iPhone), `reminder.schedule` (un tour planifié par l'agent, stocké dans la
  room console, exécuté par le service 24/7), `thread.attachments` (liste et téléchargement). Le
  👍/👎 depuis la conversation existe (`--permission-prompt-tool`), il manque son rendu dans l'app.
- Dépend de 0 pour retrouver dans le fil ; les rappels et le calendrier sont indépendants.

### 8. Le mode pilote, par fil (2 jours)

- **Vu** : pour une conversation choisie — le fil Marketplace d'une annonce, la boîte Instagram du
  commerce — l'assistant **répond seul**, dans un cadre écrit en une phrase (« dis que c'est
  disponible, propose samedi matin ou dimanche, ne baisse pas le prix, passe-moi la main si on parle
  de livraison »). Chaque réponse envoyée est marquée dans le fil et journalisée. Un interrupteur
  visible, rouge, par fil.
- **À construire** : le mode relais existe déjà sur WhatsApp (`!wa set-relay`, réponse préfixée
  « 🤖 cc : »). Il manque : l'UI par fil, le cadre stocké dans la room console, la règle de
  passage de main (l'agent répond « je préviens meffysto » et pose un brouillon), et la garde
  anti-boucle si l'interlocuteur est lui-même un bot. Sur les réseaux Meta, avertir du risque de
  bannissement pour automatisation.
- Dépend de 0 et de 2. C'est la fonctionnalité qui « vend » aux indépendants et aux vendeurs.

### 8b. Configurer sans configurer : trois niveaux, un seul fichier (3–4 jours)

Le but : simple pour quelqu'un qui n'a jamais vu un YAML, complet pour le pro qui branche son
CRM. La règle : **la persona (chantier 8, format de Buzz) est le format de stockage, jamais
l'interface.** Un fichier par fil, par réseau ou par défaut, versionné dans la room console, lu par
le Mac et l'iPhone. Trois niveaux le présentent, chacun se suffit, et tous écrivent le même fichier.

- **Niveau 1 — rien.** cc existe dès le Relais installé, a son fil, et ne fait rien ailleurs tant
  qu'on ne l'invite pas. Le seul geste : « Inviter cc dans cette conversation ». Déjà là.

- **Niveau 2 — une carte par conversation.** Dans la fiche du fil, une carte **Assistant** à trois
  positions et une phrase :
  - **Sur demande** : il répond quand on le nomme.
  - **Propose** : il prépare une réponse à chaque message, vous validez (chantier 2).
  - **Répond seul** : il envoie, dans le cadre écrit juste dessous (chantier 8). Le champ propose
    des modèles — « vendeur Marketplace », « accueil client », « famille » — qui sont des skills
    livrés avec l'app.
  Trois positions et une phrase couvrent la plupart des cas, pro compris.

- **Niveau 3 — le fichier, en formulaire.** Un bouton **Réglages avancés** ouvre un éditeur qui
  retranscrit la persona section par section : *Identité* (nom, avatar, moteur, modèle), *Quand il
  parle* (mention, mots-clés, tous les messages, horaires), *Ce qu'il sait faire* (skills cochés,
  serveurs MCP ajoutés depuis le catalogue ou à la main), *Ce qu'il ne fait jamais* (outils
  interdits, envoi sans validation, sujets), *Mémoire* (partagée entre fils ou non), *Journal*.
  Un onglet **Fichier** montre le YAML et le corps du prompt, éditables ; le formulaire se met à
  jour dans l'autre sens. Un champ inconnu du formulaire est conservé et affiché tel quel, jamais
  perdu. Le pro qui a écrit son fichier ailleurs le colle ici.

**Ce qui fait tenir l'ensemble** : aucune option sans défaut sain ; la carte du niveau 2 et le
formulaire du niveau 3 sont deux vues du même fichier, donc on ne maintient qu'un modèle ; la
validation est celle du schéma de persona, avec un message en français à côté du champ fautif, pas
une erreur de parsing.

**Portée** : une persona par fil hérite de celle du réseau, qui hérite de celle par défaut. « Au
travail, tu es sobre, tu ne tutoies pas, tu ne parles jamais d'argent » se règle une fois pour
Slack, et chaque canal peut l'affiner.

**Slack, qui arrive.** Sur les réseaux personnels l'unité est la personne ; sur Slack c'est le canal,
avec des dizaines de messages qui ne s'adressent pas à vous. Le bon défaut y est *Sur demande*, avec
un déclencheur sur la mention de *vous* ou des mots-clés, pas de cc. *Répond seul* dans un canal
d'entreprise engage l'employeur : cadre écrit obligatoire, journal lisible, marquage visible
« répondu par l'assistant de meffysto ». Et en usage pro, c'est une app Slack officielle qui sera
acceptée par un espace de travail, pas un compte utilisateur ponté par mautrix-slack — à trancher au
moment du pont.

### 9. L'inbox comme outil : `correspondance-mcp` (2–3 jours)

- **Vu** : depuis Claude Desktop, Zed ou une autre app : « qu'est-ce qui attend une réponse depuis
  deux jours ? », « prépare une réponse à Camille » → le brouillon apparaît dans Correspondance.
- **À construire** : `PLAN-relais-agents.md` § M le décrit : binaire local stdio, session du
  Trousseau, outils de lecture, `draft_reply`, `send_message` derrière liste blanche, contenu marqué
  non fiable, pas d'envoi dans le tour d'une lecture.
- Donne aussi à cc l'accès aux rooms où il n'est pas invité, pour le chantier 1.

### 10. Avoir cc en un clic (déjà planifié, prérequis pour tout tiers)

`PLAN-agents.md` phases 1–3 : la config depuis la room console, l'hôte « Ce Mac » via
`SMAppService`, l'hôte distant assisté. Sans ça, l'agent parfait n'existe que sur le NUC de meffysto.

## Ordre recommandé

1. **0 Contexte** — sans lui rien n'est vrai.
2. **1 Résumé** et **2 Réponse proposée** — la table de base, en deux semaines on est au niveau
   annoncé par Beeper, avec cinq réseaux et chez soi.
3. **5 Mémoire** — ce que personne n'a, et ce qui rend 2 bon plutôt que générique.
4. **3 Traduction** et **4 Vocaux** — petits, visibles, attendus par la cible.
5. **6 Progressif** — confort, rend l'agent vivant.
6. **7 Agir** puis **8 Pilote** — le rêve, mais seulement quand la lecture et la mémoire sont solides.
   **8b Configuration** juste après : la carte à trois positions dès que le mode pilote existe, le
   formulaire du niveau 3 quand une deuxième personne, ou Slack, en a besoin.
7. **9 MCP** et **10 Un clic** — en parallèle, dès qu'une deuxième personne veut l'essayer.

Environ 25 jours de travail pour l'ensemble, livrables un par un. Après 0+1+2 (une semaine), le
site peut à nouveau écrire « résume le groupe famille » et « propose une réponse à l'acheteur » ;
après 5, « il sait que Julie est végétarienne » ; après 8, « il répond aux acheteurs pour vous ».

## Ce qu'on prend à Buzz, en plus

`PLAN-relais-agents.md` a déjà pris ACP, le batch par canal, la politique d'auteur à quatre modes,
`!cancel` / `!rotate` / `!shutdown`, la portée de session. Une relecture du dépôt (septembre 2026)
donne huit idées de plus, chacune rattachée à un chantier.

1. **Les personas comme fichiers** (`buzz-persona`, `PERSONA_PACK_SPEC.md`). Un agent est un
   markdown à en-tête YAML : `display_name`, `model`, `subscribe`, `triggers` (`mentions`,
   `keywords`, tous les messages), `skills` chargés à la demande, `mcp_servers`, `hooks`. Le corps
   du fichier est le prompt. Précédence : variables d'environnement > réglages UI par agent >
   en-tête > défauts du pack. **Pour nous** : le cadre du mode pilote (chantier 8) *est* une
   persona par fil ; le catalogue « Ajouter un moteur » devient un catalogue de personas ; et on
   livre avec l'app des **skills** prêts (« vendeur Marketplace », « réponse client », « famille »),
   que Claude Code sait déjà charger. Un fil, une persona, trois lignes de YAML.

2. **Déclencheur par mots-clés**, en plus de la mention. Chez Buzz `triggers.keywords`. **Pour
   nous** (chantier 2) : `rooms.<id>.suggest` gagne un mode `keywords: ["dispo", "devis", "prix"]`
   — la réponse proposée n'apparaît que quand ça vaut le coup, pas à chaque « ok ».

3. **La réaction comme commande** (`buzz-workflow` : déclencheurs `message`, `reaction`, `schedule`,
   `webhook`, avec portes d'approbation). **Pour nous** : sur iPhone, une réaction est le geste le
   moins cher qui existe. Réagir 🤖 à un message = « propose-moi une réponse à ça » ; 📌 = « retiens
   ça sur cette personne » (chantier 5) ; 🌐 = « traduis » (chantier 3). Zéro saisie, zéro mention,
   et l'agent voit exactement quel message on désigne. La porte d'approbation, c'est déjà le brouillon.

4. **Le battement de cœur** (`--heartbeat-interval`, mode `nobody` : « l'agent n'agit que sur les
   prompts de battement »). Un prompt périodique, sans message entrant. **Pour nous** (chantiers 1
   et 7) : c'est le mécanisme des rappels (« jeudi, relance Noé ») et du **point du matin**
   (« qu'est-ce que j'ai raté cette nuit ? » à 8h, visible par soi seul). Une implémentation, deux
   fonctionnalités, et rien à inventer côté planification.

5. **La passation de contexte** (`buzz-agent` : quand le contexte est plein, « l'agent résume son
   propre historique et continue », `MAX_HANDOFFS` avant repli sur la troncature) et le hook
   `_PostCompact` (`MCP_DRIVEN_HOOKS.md`) qui réinjecte un état après compaction. **Pour nous**
   (chantier 5) : la mémoire par correspondant est précisément ce qu'on réinjecte après une
   compaction — sinon un fil long fait oublier à cc que Camille est végétarienne. Les hooks sont
   des outils MCP dont le nom commence par `_`, cachés au modèle, réponses encodées en JSON, budget
   de refus (3 par prompt), délai 2,5 s : la mécanique est simple et vaut d'être reprise telle quelle.

6. **« N'imposez pas la parole, imposez l'honnêteté »** (`welcome-kickoff-silent-failures.md`).
   Trois pannes silencieuses documentées : la *fausse histoire* (un minuteur écrit « ça prend plus
   de temps » et ne se corrige jamais), le *trop bruyant* (des agents qui s'accusent réception en
   boucle), le *trop silencieux* (un canal vide sans erreur visible). Règle : « pas d'accusé de
   réception nu », les faits décident, le minuteur n'est qu'un dernier recours. **Pour nous** : dans
   un groupe, cc ne dit jamais « ok noté » ; quand un tour échoue, le fil le montre (« cc n'a pas
   répondu : moteur arrêté », « délai dépassé »), au lieu d'un silence qu'on prend pour de la lenteur.
   Et la garde inverse de `buzz-agent` (`REQUIRE_REPLY` : rappel si le tour finit sans avoir posté)
   devient chez nous : « tu as été appelé et tu n'as posé ni réponse ni brouillon — dis pourquoi ».

7. **La présence est une conclusion** (`agent-availability.md`) : « la disponibilité reflète la
   présence conversationnelle sur le relais, pas la santé du processus » ; « une identité non
   interrogée est *inconnue*, jamais implicitement hors ligne » ; le bureau « ne tient aucun canal
   de gestion vers le processus distant ». C'est mot pour mot notre § « Actif est une conclusion,
   jamais une lecture » (`AGENT.md`), et ça confirme le choix. **À ajouter** : le point de présence
   sur la fiche de cc dans l'inbox, comme pour n'importe quel contact — en ligne, absent, inconnu.

8. **Une CLI JSON pour les agents** (`buzz-cli`, « agent-first, JSON in / JSON out ») à côté du
   serveur MCP. **Pour nous** (chantier 9) : `correspondance-mcp` et une commande `correspondance`
   partagent le même cœur ; la CLI coûte un après-midi de plus et rend l'inbox scriptable par
   n'importe quoi — un cron, un raccourci macOS, un agent qui ne parle pas MCP.

Deux idées qu'on regarde sans les prendre : la fenêtre de canal calculée côté relais
(`bridge-channel-window.md`, métadonnées de fil à l'ingestion, overlays signés jamais stockés) — c'est
la bonne réponse à « qu'est-ce qui attend une réponse » à l'échelle, mais Synapse n'est pas Buzz et
un sidecar sur le Relais suffira longtemps ; et la découverte d'agents possédés
(`owned-agent-discovery.md`, « le propriétaire reste la provenance, pas l'auteur ») — utile le jour
où l'agent d'un ami entre dans un groupe, pas avant.

## Ce qu'on ne fera pas

- **Envoyer sans validation par défaut.** Le mode pilote est un choix explicite, par fil, visible.
- **Lire tout le temps.** Le contexte est chargé à un tour, pas surveillé en continu ; la réponse
  proposée est opt-in par fil ; « Qu'est-ce que j'ai raté » est un geste, pas un fond.
- **Un cloud à nous.** Tout ce qui précède tourne sur le Relais ou l'appareil, avec l'abonnement
  du propriétaire. C'est la ligne qui nous sépare de Beeper, Franz et Meta, et c'est celle du site.

## Sources

- Beeper, relance et feuille de route IA (BeepMate, résumés, classement, ouverture à Claude/ChatGPT) :
  blog.tmcnet.com, « Beeper Relaunches with On-Device Messaging… », 2026.
- Franz 6, assistant intégré (rattrapage, transcription, triage, brouillons) : meetfranz.com, makerstack.co.
- WhatsApp, brouillons IA à partir du fil : techcrunch.com, 2026-03-26.
- OpenAI, intégration Apple Messages (lire, chercher, rédiger, envoyer) : 9to5mac.com, 2026-03.
- Buzz (Block, Apache 2.0) : github.com/block/buzz — `crates/buzz-persona/PERSONA_PACK_SPEC.md`,
  `crates/buzz-acp/README.md`, `crates/buzz-agent/README.md`, `docs/MCP_DRIVEN_HOOKS.md`,
  `docs/agent-availability.md`, `docs/welcome-kickoff-silent-failures.md`, `docs/bridge-channel-window.md`,
  `docs/owned-agent-discovery.md`, `docs/remote-agents.md`.
