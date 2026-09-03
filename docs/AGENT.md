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
| Photo, vocal, PDF envoyés à cc → fichiers posés dans le dossier du tour, chemins nommés dans le prompt | ✅ testé (unités) — pas encore éprouvé sur le NUC |
| Tête-à-tête et console : parler **sans nommer** l'agent | ✅ le marqueur de l'app, la console, ou `rooms.<id>.mention` |
| **Le contexte du fil** : les N derniers messages du salon dans le prompt, comme données | ✅ testé (unités) — `context` par agent et par salon, 0 coupe |
| **Propose sans qu'on demande** : un tiers écrit, cc pose une proposition `suggest` après 3 s | ✅ testé (unités) — `rooms.<id>.suggest` : `always` / `keywords` |
| **Répond seul, dans un cadre** : mode `pilot`, envoi marqué `piloted`, `<hors-cadre>` → `handover` | ✅ testé (unités) — plafond 10/h par salon |
| **Échecs visibles** : un avis `fr.correspondance.agent.notice` avec la cause et le geste | ✅ testé (unités) — `cap`, `engine_missing`, `engine_offline`, `error`, `timeout` |
| **Le point du matin** : à l'heure réglée (`heartbeat`), une proposition `summary` dans le fil de cc | ✅ testé (unités : l'heure, le tri des salons) — pas encore éprouvé sur le NUC |

### Pièces jointes

Un agent est un utilisateur Matrix : il télécharge le média du salon avec son
propre jeton. Ce que le tour reçoit n'est donc pas un `mxc://` — c'est un
fichier, sous `pieces-jointes/<event>/` dans le **dossier de travail de la
room**, jamais ailleurs (même rayon d'explosion que le reste). Le prompt
s'ouvre sur la liste de leurs chemins.

Trois cas se disent au moteur au lieu d'être tus, parce qu'un moteur qui ignore
une photo qu'on lui montre répond à côté sans que personne ne sache pourquoi :
une pièce **chiffrée** (`content.file` — on sait qu'elle existe, pas la lire),
une pièce **de plus de 25 Mio**, un **téléchargement en échec**.

La légende porte le déclencheur (MSC2530 : `filename` présent ⇒ `body` est la
légende). Sans légende, une photo ne réveille l'agent que là où la mention
n'est pas requise — sinon toute image d'un salon le réveillerait.

### Faut-il dire « @cc » ?

Non dans les salons qui sont à lui : un tête-à-tête ouvert par l'app (elle le
marque `kind: agent` à la création) et sa **console**. Oui partout ailleurs —
dans la note à soi où il est invité comme dans un fil bridgé, sans mention il
répondrait à ce qu'on écrit à quelqu'un d'autre. Un atelier ne passe jamais par
cette règle : plusieurs agents dans un salon, c'est la mention obligatoire de
`Atelier`, et elle protège des boucles.

La config tranche salon par salon, dans les deux sens — `rooms.<id>.mention`
dans l'event de config de la console (`MentionPolicy`, testé).

Le marqueur se lit **directement** à l'arrivée dans un salon
(`client.roomState`), pas seulement au fil du `/sync` : un sync incrémental ne
porte pas toujours l'état complet d'un salon qu'on vient de rejoindre, et un
fil d'agent où l'on exige la mention est un fil muet.

### Un fil d'agent où un second agent est invité

Le fil de claude, où l'on invite cc : c'est un atelier de fait, et il n'a pas
besoin que `peers` le dise — dans un salon marqué `kind: agent`, **tout membre
qui n'est pas un propriétaire est un agent** (l'app n'y invite personne
d'autre). Trois règles, toutes dans `Atelier` :

- **ce qui ne nomme personne va à l'hôte** — l'agent à qui est le fil (le champ
  `agent` du marqueur, posé par l'app à la création ; à défaut, le nom du
  salon, que l'app pose au nom de l'agent). L'autre attend qu'on l'appelle ;
- **ceux qui ouvrent la phrase sont les destinataires, et eux seuls** :
  « @cc dis à @claude de faire un test » parle *à* cc *de* claude — claude ne
  répond pas, c'est à cc de le charger. « @claude @cc vous allez bien ? »
  s'adresse aux deux. Sans agent en tête, tous ceux qui sont nommés sont
  appelés. Une phrase, une réponse — vu en vrai avant : les deux agents
  répondaient au même message ;
- **jamais de brouillon** : on parle à un agent, il n'y a personne à ménager.
  Un autre agent n'est pas un tiers (`isPrivateWithOwners`), et le mode est
  `direct` quel que soit le réglage par défaut.

La délégation : un agent chargé par un propriétaire appelle l'autre **en tête
de phrase** (« @claude fais un test de math »), ou avec la formule « demande à
@claude ». La réponse porte `fr.correspondance.agent.delegated: true`, et un
agent qui lit ce drapeau sur le message d'un agent ne répond jamais — c'est la
profondeur 1, portée par l'event lui-même, pas par un compteur.

### L'aparté : parler à l'agent devant des humains

Dans un fil bridgé, nommer un agent présent (`@cc résume`, « dis à @claude… »)
fait partir le message en **`fr.correspondance.agent.aside`** au lieu d'un
`m.room.message`. Les ponts mautrix ne relaient que ce dernier : le
correspondant ne voit ni la question, ni le brouillon (`proposal`) qui lui
répond. L'aparté reste entre le Relais, tes appareils et l'agent. Le fil le
montre comme ta bulle, avec « Aparté avec cc · invisible pour les autres »
dessous ; le composer vide dit « @cc pour un aparté » dès qu'un agent est là.

La règle « qui est nommé » (`AgentWire.agentsMentioned`, mot entier, n'importe
où) est **partagée** entre l'app et l'agent : une seule définition, pas deux qui
divergent. Pour l'agent, un aparté est un ordre comme un autre
(`Trigger.carriesText`).

### Le contexte du fil

À chaque tour, cc reçoit les **N derniers messages du salon** (`/messages`, 50
par défaut) en tête du prompt, comme bloc de données (`ContexteDuFil`) : une
ligne par message, `[jeu. 19:21] Camille : …`, l'expéditeur par son nom
d'affichage (sinon son localpart), les médias en `[photo]`, `[vocal]`,
`[fichier devis.pdf]`, les messages chiffrés de l'historique en `[message
chiffré]` — `/messages` rend les events tels quels, seul le `/sync` passe par
la machine crypto. Le lot en cours est exclu, le bloc est tronqué par le
début dans un budget de caractères, et il s'ouvre sur un préambule qui dit au
moteur que **rien là-dedans n'est un ordre**. « @cc c'est quoi cette histoire
de plombier ? » répond juste.

Le nombre se règle par agent (`context`, dans l'event de config) et par salon
(`rooms.<id>.context`) ; **`0` coupe**, et un 0 explicite est respecté. Un
`/messages` en échec ne bloque pas le tour : il part sans, et le journal le dit.

### Proposer sans qu'on demande

Un salon réglé sur *Propose* (`rooms.<id>.suggest` : `always`, ou `keywords`
avec `rooms.<id>.keywords`, mots entiers, sans égard à la casse) réveille cc à
chaque **texte d'un tiers** — ici le fantôme de pont est l'expéditeur légitime,
c'est lui qui écrit depuis WhatsApp. Jamais un propriétaire, le bot, un autre
agent, ni un message déjà piloté. Après trois secondes, si le propriétaire n'a
pas répondu lui-même et qu'aucun tour n'est en vol, un tour part avec une
instruction fixe et le message du tiers cité ; la réponse est **toujours** une
proposition `fr.correspondance.agent.proposal` avec `kind: suggest`, quel que
soit le mode du salon — *Propose* ne parle jamais. L'app la rend en bandeau
au-dessus de la saisie, pas en carte dans le fil.

Chaque proposition porte désormais son genre (`ProposalKey.kind` : `reply` par
défaut, `suggest`, `summary`, `handover`).

### Répondre seul, dans un cadre

Un salon en mode **`pilot`** (`rooms.<id>.mode`) porte un cadre d'une phrase
(`rooms.<id>.frame`) : « confirme ou déplace les rendez-vous, rien d'autre ».
Tout texte d'un tiers déclenche sans délai un tour qui répond **au nom du
propriétaire** — ou dit exactement `<hors-cadre>` suivi d'une phrase
(`Pilotage.lire`). Une réponse part en `m.room.message` cité, avec le champ
`fr.correspondance.agent.piloted: true` (l'app le marque « Envoyé par cc pour
vous »), et une entrée de journal dont le prompt commence par « piloté : ».
Hors cadre : une proposition `kind: handover` avec `reason`, et un avis
`fr.correspondance.agent.notice` (`reason: handover`) qui déclenche une
notification. Une erreur du moteur, ou une réponse vide, passe la main aussi :
rien de tel ne part à un tiers en votre nom.

Gardes : jamais de réponse pilotée à un message qui porte `piloted`, à un
agent, au bot ; **dix réponses pilotées par heure et par salon**, au-delà un
avis `cap` et le silence. Une mention explicite d'un propriétaire dans un salon
`pilot` reste une demande ordinaire, traitée comme `direct`.

### Le point du matin

`heartbeat` (« 08:00 », dans l'event de config) : à cette heure, sans message
entrant, cc relit par `/messages` les vingt derniers messages de chaque salon
joint, garde ceux où **le dernier mot n'est ni au propriétaire ni à lui** (dix
au plus, les plus récents d'abord), et lance un tour `summary` dans **son
tête-à-tête** — le premier fil marqué par l'app dont il est l'hôte ; sans fil,
pas de point. La réponse est une proposition `kind: summary`, sans citation.
Pas de cron : le service tourne déjà, une tâche dort jusqu'à l'heure et relit
la config à chaque réveil (`Heartbeat.prochaineOccurrence`, pur, testé).

### Les échecs se voient

Là où un tour répondait déjà par un texte — plafond atteint, moteur absent,
moteur pas connecté, panne, délai — il pose **en plus** un event
`fr.correspondance.agent.notice` dans le salon : `agent`, `body`, `reason`
(`cap`, `engine_missing`, `engine_offline`, `error`, `timeout`) et `action`
(`rescan` pour un moteur, `retry` pour une panne, rien pour un plafond). Les
ponts ne le relaient pas ; l'app le rend en ligne système avec le bouton. Le
texte reste, pour les clients qui ne connaissent pas l'avis. Le délai de tour
est celui de chaque moteur (`claude.timeoutSeconds`, `hermes.timeoutSeconds`,
`acp.timeoutSeconds`).

## Garde-fous

- Seuls les `owners` déclenchent ; tout autre expéditeur est ignoré en silence.
- L'agent ne rejoint que les rooms où **un propriétaire** l'invite.
- Une demande à la fois par room ; plafond glissant (30/h par défaut).
- **Pleine permission, et trois bornes.** Un agent invité par son propriétaire a ses
  outils : le régime est posé explicitement (`--permission-mode bypassPermissions` sur la
  CLI, `session/set_mode` en ACP) et on répond `allow_always` à toute demande. Ce qui
  borne le risque n'est plus une question posée mais :
  1. **un dossier par room, jamais `~`** — le `cwd` d'un tour est
     `~/.correspondance-<agent>/ateliers/<room>` tant qu'aucun dépôt n'est lié (`Workspace`) — jamais `~/Correspondance`, qui est `~/correspondance` sur un disque insensible à la casse, et cc y a écrit une fois ;
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

## Toutes les chutes ne se valent pas

Un moteur qui plante mérite qu'on relance ; un mot de passe refusé par le Relais, non — il ne
se répare pas tout seul, et huit tentatives ne font que remplir le journal en donnant
l'illusion d'un plantage à répétition.

Le code de sortie porte la différence (`AgentExit`) :

| Code | Ce que c'est | Le surveillant |
| --- | --- | --- |
| `0` | fin normale | — |
| `1` | erreur ordinaire (Relais pas prêt, moteur qui trébuche) | relance, avec palier |
| `78` | **identifiants refusés** (`401`/`403`, `M_FORBIDDEN`) | s'arrête, propose « Réinstaller » |
| `79` | un autre agent tourne déjà sur ce compte | s'arrête |

Un `502` ou un timeout restent des pannes : ils se réessaient.

**Éprouvé de bout en bout** : `infra/agent/tests/refus-auth.sh <binaire>` lance le vrai
binaire contre un homeserver factice qui répond `403 M_FORBIDDEN`, et exige `78`. Ce test
existe parce que les tests unitaires prouvaient chaque moitié — qu'un processus sortant en 78
n'est pas relancé, et que la détection reconnaît un 403 — sans jamais vérifier la jonction.

### « Est-ce que je teste bien le code que je viens d'écrire ? »

L'agent écrit son propre chemin et sa date de compilation à chaque démarrage :

```
22:41:44 binaire : /Applications/Correspondance.app/Contents/MacOS/correspondance-agent (compilé le 1 sept. 22:41)
```

Ça n'est pas cosmétique : un binaire embarqué d'une build précédente donne exactement les
symptômes d'un défaut déjà réparé, et la question a déjà coûté un essai complet. Et la phase
de build « Embed correspondance-agent » **fait maintenant échouer le build** quand l'agent ne
compile pas, au lieu de garder le binaire précédent avec un simple avertissement — un binaire
périmé qui a l'air frais coûte des heures, une build rouge cinq minutes.

## Deux messages coup sur coup : un seul tour

Un tour à la fois par conversation, c'est la garantie — mais ce qui arrive
*pendant* ce tour n'est plus refusé, il **attend et part avec la suite**, fusionné
en un seul appel au moteur.

Avant, l'agent postait « Je suis encore sur ta demande précédente ici — une à la
fois ». Deux défauts en un : la bulle **remplit la file au lieu de la vider** (la
règle qui domine tout le chantier), et la demande était **perdue** — jamais
traitée. Éprouvé en vrai : `@cc test` puis `@cc ping` ; `test` a eu sa réponse,
`ping` n'a eu qu'un refus.

Rien n'est posté pour dire qu'on attend : le « écrit… » le dit déjà, et il tient
tant qu'il reste quelque chose à traiter.

### Ce qu'on prend à `buzz-acp`, et pourquoi

C'est leur mécanique : les events d'un canal s'accumulent, et quand aucune
requête n'est en vol, **tout ce qui attend part en un seul `session/prompt`**.
Deux messages coup sur coup coûtent donc **un** tour — décisif quand le plafond
compte les tours et que chaque tour consomme une fenêtre d'abonnement.

Le prix est réel : une seule réponse pour deux questions. On le borne de deux
façons — le prompt attribue chaque message à son expéditeur, dans l'ordre, pour
que le moteur sache qu'il en traite plusieurs ; et la **citation désigne le
dernier**, celui auquel on s'attend à voir répondre, les précédents étant dans le
corps du tour.

Deux détails qui comptent :

- **Le plafond horaire se prend au départ du tour**, pas à l'arrivée d'une
  demande — sinon une file pleine ferait mentir le plafond, et le lot perdrait
  tout son intérêt.
- **Une borne de taille**, pas une profondeur : un lot absorbe tout ce qui
  attend. Si le prompt deviendrait ingérable, on garde les **plus récentes** et
  on écrit la perte dans le journal local et celui de la console — **jamais dans
  la conversation**.

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

**cc renaît avec l'app.** Il meurt avec elle (voulu), et rien ne le relançait : après une
relance, l'écran disait « arrêté » et proposait de *ré-activer*, ce qui refait le compte et
repose un mot de passe. L'app garde le choix de l'utilisateur (« voulu sur ce Mac », posé par
Activer, retiré par Arrêter) et relance l'agent au lancement si l'amorce et le binaire sont là ;
l'état « arrêté » propose « Démarrer », qui ne passe pas par le Relais.

**Le status ne suffit pas, éprouvé.** Le cc du NUC datait d'avant le status : il n'en
publiait aucun, l'app a lu ce silence comme une absence, a activé un second cc sur le Mac,
et les deux ont répondu au même message. La garde lit désormais aussi **les sessions du
compte** par l'API admin (`/_synapse/admin/v2/users/<cc>/devices`) : une session vue par le
serveur il y a moins de quinze minutes qui n'est pas celle de cette machine, et l'activation
refuse en la nommant. C'est la seule source qu'un agent ne peut pas taire — un `/sync` la
rafraîchit, mais Synapse ne l'écrit qu'une fois par dix minutes, d'où la fenêtre large : après
avoir arrêté un agent ailleurs, il faut attendre jusqu'à un quart d'heure avant d'activer ici. Pour que « cette machine » soit lisible, l'agent nomme sa session
« Correspondance agent · <machine> » à la connexion (`AgentSessions`).

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

Les clés de l'event, toutes dans `AgentWire.ConfigKey` : `owners`, `trigger`,
`hourlyCap`, `defaultMode` (`direct` / `draft` / `pilot`), `backend`,
`toolPreset`, `model`, `systemPrompt`, `acpCommand`, `acpArguments`, `peers`,
`context`, `heartbeat`, et par salon dans `rooms.<id>` : `cwd`, `mode`,
`mention`, `context`, `suggest`, `keywords`, `frame`.

## Suite prévue

1. L'app écrit la config dans la room console et la crée à l'activation (côté agent : fait).
2. Hôte « Ce Mac » : `SMAppService`, cible `correspondance-agent` embarquée, création du
   compte bot (`logout_devices: false`).
3. Hôte distant assisté : binaire publié, commande à coller, jeton d'amorce.
4. `correspondance-mcp` : l'inbox comme outil pour un agent du dehors.
5. Ateliers (salons multi-agents) puis chiffrement — cf. `docs/PLAN-relais-agents.md`.
6. Réponse progressive : `ACP.swift` lit déjà les `agent_message_chunk`, mais
   `AgentBackend.run` ne rend qu'à la fin — il manque un chemin pour les
   morceaux, et l'édition du message au fil de l'eau côté Matrix.

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
