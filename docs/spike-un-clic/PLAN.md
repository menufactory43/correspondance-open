# Spike « un clic » — trois phases, un agent qui code, un vérificateur par phase

Branche `relais-un-clic`, worktree `~/correspondance-un-clic`. Contexte et décisions dans
`docs/PLAN-relais-un-clic.md`. Ce document est le contrat de chaque phase : ce qu'on prouve,
ce qu'on mesure, ce qu'on rend. Chaque phase finit par un rapport `docs/spike-un-clic/phase-N.md`
avec les **commandes et leurs sorties** — pas des affirmations. Une phase sans preuve est
une phase non faite.

## Règles absolues, pour toutes les phases

- **Ne jamais toucher à la prod** : ni les conteneurs `correspondance-*` du NUC (hors `-essai`),
  ni `~/.correspondance-agent/`, ni `~/Library/Application Support/Correspondance/`, ni le
  DerivedData par défaut. Le spike vit sous `~/.correspondance-unclic/` sur le Mac et sous
  `~/unclic/` sur le NUC. Toute build Xcode passe par `-derivedDataPath /tmp/dd-unclic`.
  L'app s'éprouve avec `CORRESPONDANCE_HOME=unclic`.
- **Ne jamais lier un vrai compte WhatsApp, Signal, Instagram ou Messenger** au Relais du
  spike : un second pont sur le même compte débranche le vrai, sur le NUC. Faire apparaître le
  QR suffit ; on ne le scanne pas.
- **Aucun sudo, aucun Docker, aucun Homebrew dans la pile livrée.** Si un outil de build
  (Go) manque sur le Mac, on l'installe par `brew` **pour construire**, et on le dit ; le
  produit final n'en dépend pas.
- **Tout binaire externe est épinglé** (version exacte + sha256 relevé et écrit dans le
  rapport), téléchargé depuis les releases officielles du projet.
- Le Mac de développement est une machine réelle : ports libres à vérifier avant de lier
  (`lsof -i :PORT`), aucun processus laissé orphelin à la fin d'une phase (fournir un
  `stop.sh`).
- Le NUC est `ssh nuc`, x86_64, sans Go, avec Docker qu'on **n'utilise pas** ici. Il tient
  lieu de « VPS vierge » : tout sous `~/unclic/`, ports 8010 et suivants, `systemd --user`.
- Commits sur la branche, messages en français dans le style du dépôt (une phrase qui dit ce
  qui a changé et pourquoi, pas un titre). Ne pas commettre de secrets ni de bases de données.

## Ce qu'on sait déjà, et qui borne les phases

- L'app et l'agent utilisent quatre appels d'administration propres à Synapse :
  `_synapse/admin/v2/users/{id}` (création de compte, ×2), `…/users/{id}/devices` (la garde
  qui empêche un second cc, commit `60c600a`), `_synapse/admin/v1/users/{id}/admin`,
  `_synapse/admin/v1/rooms/{id}/make_room_admin`. Le bootstrap utilise
  `register_new_matrix_user` (secret partagé).
- Le client Matrix (`Packages/CorrespondanceCore/Sources/CorrespondanceMatrixClient`) n'a
  **aucun** support du chiffrement : pas de `m.room.encrypted`, pas de machine Olm. Activer
  le chiffrement des portails aujourd'hui rendrait l'app aveugle.
- Le code d'appairage `correspondance://relais/…` est émis par `infra/matrix/bootstrap.sh`
  et lu par `SettingsMatrixPane` (six mots de vérification). Le spike doit finir par ce code,
  et par l'app qui s'y connecte.
- Mesures de référence, NUC, Docker : Synapse 1 utilisateur 340 Mo + Postgres 220 Mo ;
  ponts 12–62 Mo ; Synapse d'essai vide 120 Mo.

---

## Phase 1 — Continuwuity × mautrix, sur ce Mac, sans conteneur (le spike qui décide du poids)

**Question** : un Relais fait de binaires (Continuwuity + ponts mautrix Go) fait-il tourner
l'app et l'agent tels qu'ils sont, ou avec quelles adaptations ?

**À faire**
1. Poser Continuwuity (release officielle, macOS arm64, version épinglée) sous
   `~/.correspondance-unclic/relais/`, `server_name = unclic.local`, port 8010, stockage
   RocksDB dans ce dossier, sans sudo. Un `start.sh` / `stop.sh`.
2. Créer le compte propriétaire `@essai:unclic.local` et vérifier `/login` par mot de passe
   (celui que l'app utilise), `/sync`, création d'un salon.
3. Construire ou télécharger `mautrix-whatsapp` et `mautrix-signal` (versions épinglées, les
   mêmes que `infra/matrix/docker-compose.yml` si possible), en SQLite, enregistrés comme
   application services dans Continuwuity. Preuve : le salon de gestion s'ouvre, `help`
   répond, `login qr` rend un QR (**ne pas le scanner**). Signal : au moins démarre et
   répond à `help` (libsignal en cgo est le plus lourd à construire — dire ce que ça coûte).
4. **La matrice de compatibilité** : pour chacun des quatre appels `_synapse/admin` et pour
   la création de compte, ce que Continuwuity offre (endpoint compatible, commande admin,
   rien). Tester, pas lire. Dire précisément ce qu'il faudrait changer dans
   `MatrixBridgeService` / `AgentProvisioning` / le bootstrap.
5. Émettre un code d'appairage au même format que `bootstrap.sh`, construire l'app depuis ce
   worktree (`-derivedDataPath /tmp/dd-unclic`), la lancer avec `CORRESPONDANCE_HOME=unclic`,
   coller le code. **Preuve** : « Synchronisé avec le Relais », la « Note à soi » apparaît,
   un message posté dedans revient par `/sync`. Capture d'écran dans le rapport.
6. Si le temps le permet : cc (`correspondance-agent`) activé sur ce Relais avec un dossier
   d'amorce **à part** (pas `~/.correspondance-agent/`) — dire si la garde des sessions
   (appel devices) passe ou casse.
7. Mesurer : RSS de chaque processus après 5 minutes, temps de démarrage à froid, taille sur
   disque, taille des binaires. Comparer à la référence NUC.
8. En contrepoint, si Continuwuity échoue sur un point bloquant : Synapse posé par `uv` en
   SQLite dans le même dossier, mêmes mesures, pour que le rapport tranche entre les deux.

**Rendu** : `phase-1.md` avec versions + sha256, matrice de compatibilité, mesures, capture,
et un verdict en une phrase : *viable tel quel / viable avec ces N changements / pas viable,
Synapse par uv à la place*. Plus `infra/relais-spike/` avec les scripts qui reproduisent.

---

## Phase 2 — Le chiffrement dans le client : un spike de déchiffrement, pas un drapeau

**Question** : combien coûte réellement de rendre l'app capable de lire et d'écrire dans un
salon chiffré, avec le client Swift existant ?

**À faire**
1. Ajouter la machine crypto de matrix-rust-sdk au client, par ses bindings Swift officiels
   (`matrix-rust-components-swift`, version épinglée) ou par `matrix-sdk-crypto-ffi` seul, en
   dépendance SPM de `CorrespondanceMatrixClient`. Dire ce que ça pèse dans le bundle.
2. Brancher le minimum dans le `/sync` existant : envoi des clés d'appareil, traitement des
   `to_device`, réception des clés de salon, déchiffrement de `m.room.encrypted` en clair
   avant que le reste du pipeline le voie, chiffrement à l'envoi dans un salon chiffré.
   Persistance de la machine crypto sous le dossier de l'app.
3. **Preuve** sur le Relais de la phase 1 : la « Note à soi » créée **chiffrée**
   (`m.room.encryption`), un message posté, l'app relancée, le message relu. Puis un second
   appareil (une session du même compte lancée par un script ou par l'agent) reçoit la clé et
   lit le message — c'est ce qui prouve le partage de clés, pas seulement le cache local.
4. Activer `encryption.allow/default: true` dans la config du pont WhatsApp du spike et
   vérifier que le salon de gestion devient chiffré et que `help` se lit encore dans l'app.
5. Dire ce qui reste pour le vrai chantier E : sauvegarde des clés avec phrase, vérification
   d'appareil, cc et l'extension de notification iOS qui partagent le même client, et les
   états « chiffré / chiffré par le pont / en clair » à afficher.

**Rendu** : `phase-2.md` avec la preuve (journal du sync montrant un `m.room.encrypted`
déchiffré, capture), le poids ajouté, et une estimation honnête du chantier E en jours, avec
ce qui est fait et ce qui reste. Le code reste derrière un drapeau tant que ce n'est pas
complet.

---

## Phase 3 — La pile en binaires, posée par une commande, sur Mac et sur Linux

**Question** : la même pile se pose-t-elle sans commande sur ce Mac et avec une commande sur
une machine Linux vierge, et finit-elle par le code d'appairage que l'app lit ?

**À faire**
1. `infra/relais/install.sh` : détecte l'hôte (macOS arm64 / Linux x86_64 et arm64),
   télécharge les binaires épinglés avec vérification sha256, génère les configurations
   (homeserver, ponts, appservices), crée le compte propriétaire, pose les services
   (`launchd` agents utilisateur sur Mac ; `systemd --user` + `loginctl enable-linger` sur
   Linux, en disant si linger demande sudo), attend que le Relais réponde, **et finit sur la
   preuve** (« le Relais répond, connecté comme @… ») puis le code d'appairage. `--dry-run`
   imprime le plan. `uninstall.sh` retire tout proprement.
2. Sur Linux, Tailscale : si absent, l'installeur le pose (script officiel, ça demande sudo,
   à dire) et met l'adresse du tailnet dans le code d'appairage, comme `install.sh` le fait.
   Sur Mac, il ne pose pas Tailscale et le dit.
3. **Preuve Mac** : depuis un dossier vide (`~/.correspondance-unclic` supprimé), une seule
   commande, aucune question, le code apparaît, l'app (`CORRESPONDANCE_HOME=unclic`) se
   connecte. Redémarrage de session simulé : `launchctl kickstart` ou déconnexion/reconnexion,
   le Relais revient seul.
4. **Preuve Linux** : sur le NUC, `~/unclic/` vide, la commande depuis `ssh nuc`, sans Docker,
   ports 8010+, l'app sur ce Mac se connecte par le tunnel `ssh -N -L` (le NUC n'expose que
   `127.0.0.1`, comme le Relais d'essai). Un reboot du service (`systemctl --user restart`)
   et il revient.
5. Mesurer sur les deux hôtes : mémoire, démarrage, disque, temps total de la commande.
6. Tests : le `--dry-run` sous `infra/relais/tests/`, dans l'esprit de
   `infra/matrix/tests/install-plan.sh`.

**Rendu** : `phase-3.md` avec les deux transcriptions complètes (Mac et NUC), les mesures, et
ce qui manque encore pour la carte « sur ce Mac » dans l'app (bouton qui lance l'installeur
et colle le code seul) et pour la publication dans `correspondance-releases`.

---

## Vérification, entre chaque phase

Le vérificateur rejoue les preuves clés lui-même : lance `start.sh`, appelle le Relais,
ouvre l'app sur `unclic`, lit les mesures. Il n'accepte pas une phase sans sorties de
commandes, et renvoie la phase avec des questions précises si une preuve manque. La phase
suivante ne commence pas avant.

## Conclusion attendue

`docs/spike-un-clic/CONCLUSION.md` : la pile retenue (Continuwuity ou Synapse par uv), ce
qu'il faut changer dans l'app (liste des appels Synapse à remplacer), le coût réel du
chiffrement, la commande d'installation telle qu'un utilisateur la verra, et ce qui reste
avant un DMG : les deux cartes, la notarisation, la publication, le push.
