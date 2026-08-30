# Matrix, WhatsApp & Instagram — installation, usage, dépannage

Correspondance parle WhatsApp et Instagram par des ponts : un homeserver **Synapse** privé, les
bridges **mautrix-whatsapp** et **mautrix-instagram**, tous sur le NUC, joints depuis le Mac par
Tailscale. iMessage et Signal restent natifs et ne passent pas par là.

```
                                                 ┌─► mautrix-whatsapp  ──► WhatsApp
Mac (Correspondance) ──Tailscale──► Synapse ─────┤
                       100.64.0.7:8008       └─► mautrix-instagram ──► Instagram DM
```

Un seul `/sync` côté app pour les deux ponts (même homeserver), mais **un salon de gestion par
pont** : `@whatsappbot` et `@instagrambot` ne se parlent pas.

## 0. Ce qui tourne déjà, et où

Sur le NUC (`ssh nuc`, user `meff`, **pas de sudo**, `docker-compose` 1.29 — jamais `docker compose`) :

| Conteneur | Image | Rôle |
| --- | --- | --- |
| `correspondance-synapse` | `matrixdotorg/synapse` | homeserver, `server_name: correspondance.local` |
| `correspondance-postgres` | `postgres:16-alpine` | base de Synapse et des bridges |
| `correspondance-mautrix-whatsapp` | `dock.mau.dev/mautrix/whatsapp:v26.08` | pont WhatsApp (tag **épinglé**) |
| `correspondance-mautrix-meta` | `dock.mau.dev/mautrix/meta:ig-v26.08` | pont Instagram (tag **épinglé**, préfixe `ig-`) |

Depuis la v26.08, `mautrix-meta` ne fait plus que Messenger : Instagram est passé au binaire
`mautrix-instagram`, publié sur **la même image Docker** avec un tag préfixé `ig-`. Le
`/docker-run.sh` de cette variante appelle encore `/usr/bin/mautrix-meta`, qui n'y est plus — le
compose court-circuite donc l'entrypoint et lance `/usr/bin/mautrix-instagram` directement.

Tout vit dans `~/correspondance-matrix/` : configs générées, données, et `CREDENTIALS.txt`
(chmod 600) qui contient le mot de passe du compte `@meffysto:correspondance.local`. Ce fichier ne
quitte jamais le NUC et n'est pas versionné.

Les sources d'infra sont dans `infra/matrix/` (compose, templates, `bootstrap.sh`). Le script est
idempotent : `./infra/matrix/bootstrap.sh` depuis le Mac recopie et réapplique tout sans dégât.

Chaque pont a sa base Postgres (`mautrix_whatsapp`, `mautrix_meta`) et sa registration côté
Synapse (`whatsapp-registration.yaml`, `meta-registration.yaml`). `bootstrap.sh` les installe par
la même fonction `setup_bridge` : config par défaut → fusion des overlays du repo → registration.

### Pourquoi `127.0.0.1:8008` mais un accès en `100.64.0.7:8008`

Tailscale tourne sur le NUC en **userspace-networking** : il n'y a aucune interface `tailscale0`,
donc l'IP `100.64.0.7` n'est pas assignable en `bind`. `tailscaled` relaie lui-même le trafic
entrant du tailnet vers le `127.0.0.1` de l'hôte. Synapse écoute donc en loopback
(`ports: 127.0.0.1:8008->8008`) et reste joignable depuis n'importe quelle machine du tailnet en
`http://relais.exemple.ts.net:8008`, sans jamais être exposé sur le LAN 192.168. C'est voulu : ne pas
« corriger » ce bind en `0.0.0.0`.

Vérification depuis le Mac :

```sh
curl -s http://relais.exemple.ts.net:8008/_matrix/client/versions | head -c 120
```

## 1. Connexion dans l'app

**Correspondance › Réglages › Matrix** :

1. **Homeserver** : `http://relais.exemple.ts.net:8008` (pré-rempli).
2. **Identifiant** : `meffysto` (pré-rempli). Le MXID complet est `@meffysto:correspondance.local`.
3. **Mot de passe** : celui de `~/correspondance-matrix/CREDENTIALS.txt` sur le NUC.
4. **Connexion**. L'app ping d'abord le homeserver — un mot de passe n'est jamais envoyé à une
   mauvaise adresse.

Le jeton d'accès part dans le **Trousseau** (jamais dans UserDefaults, jamais dans le repo). La
ligne « État » affiche ensuite le MXID connecté et le décompte des fils par réseau
(« 12 WhatsApp · 3 Instagram »). **Déconnecter Matrix** révoque le jeton côté serveur, vide le Trousseau et le cache disque des conversations.

Pas de chiffrement de bout en bout côté client : le homeserver est privé, sur Tailscale, et les
salons de bridge sont créés non chiffrés (`encryption.allow: false`).

## 2. Connecter WhatsApp — le QR

Une fois Matrix connecté, **Réglages › Matrix › Connecter WhatsApp…**.

Ce qui se passe : l'app ouvre (ou retrouve) le DM de gestion avec `@whatsappbot:correspondance.local`,
y envoie `login qr`, puis interroge le salon jusqu'à voir la réponse du bot. Le bot poste un
`m.image` ; l'app le télécharge par l'endpoint **média authentifié**
`/_matrix/client/v1/media/download/…` (`Authorization: Bearer …` — obligatoire depuis Matrix 1.11,
avec repli sur l'ancien `/_matrix/media/v3/download` pour les Synapse plus vieux) et l'affiche dans
la feuille.

Sur le téléphone : **WhatsApp › Réglages › Appareils liés › Lier un appareil**, puis scanner.

- Le QR n'est valable que quelques dizaines de secondes ; le bot en renvoie un nouveau tant que le
  login n'a pas abouti. Le bouton **Relancer** de la feuille redemande un QR au bot.
- Au succès, le bot annonce « Successfully logged in » et le backfill démarre : les conversations
  WhatsApp apparaissent dans l'inbox au fil des `/sync`. Le premier remplissage prend quelques minutes.
- **Fermer** la feuille arrête l'interrogation, mais **n'annule pas** un login en cours côté bridge.
  Pour l'annuler franchement, envoyer `cancel` au bot (voir plus bas).

### Repli : code d'appairage (`login phone`)

Si le QR est refusé (caméra capricieuse, écran illisible, WhatsApp qui boude), mautrix-whatsapp
v26.08 accepte l'appairage par numéro. Dans le DM avec `@whatsappbot`, envoyer :

```
login phone +33612345678
```

Le bot répond un code à 8 caractères, à saisir dans **WhatsApp › Appareils liés › Lier avec un
numéro de téléphone**. La feuille de l'app affiche ce code si elle est ouverte ; sinon, Element Web
pointé sur `http://relais.exemple.ts.net:8008` fait très bien l'affaire pour dialoguer avec le bot.

### Ouvrir un fil vers un numéro

`NewConversationSheet` (WhatsApp sélectionnable seulement si Matrix est connecté) envoie au bot la
commande `pm +33612345678`. Le bot crée le portail et le salon arrive au `/sync` suivant.

## 2 bis. Connecter Instagram — les cookies

Meta n'offre aucun appairage par QR pour les DM Instagram : `mautrix-instagram` se connecte avec
les cookies d'une session de navigateur déjà ouverte. C'est le seul flow que le bridge expose
(`login` → étape `fi.mau.meta.cookies`).

**Réglages › Matrix › Connecter Instagram…** ouvre la feuille : l'app envoie `login` à
`@instagrambot:correspondance.local`, le bot répond « Enter a JSON object with your cookies, or a
cURL command copied from browser devtools. » puis l'URL de connexion, et la feuille attend le
collage.

Récupérer les cookies, dans un navigateur **connecté à instagram.com** :

1. Outils de développement (⌥⌘I) → onglet **Application** (Chrome) / **Stockage** (Firefox).
2. **Cookies** → `https://www.instagram.com`.
3. Relever `sessionid`, `csrftoken`, `ds_user_id`, `mid`, `ig_did` — les cinq **obligatoires**.
   `rur`, `shbid`, `shbts` sont optionnels et n'empêchent rien s'ils manquent.
4. Coller dans la feuille un objet JSON :

```json
{"sessionid":"…","csrftoken":"…","ds_user_id":"…","mid":"…","ig_did":"…"}
```

Une commande **cURL** copiée depuis l'onglet Réseau (« Copy as cURL ») fait aussi l'affaire : le
bot en extrait l'entête `Cookie` tout seul. Dans les deux cas, le message est **rédigé** par le
bot juste après lecture — les cookies ne restent pas dans l'historique du salon.

Au succès, le bot répond « Logged in as <nom> (<id>) » et le backfill démarre. Les échecs sont
explicites : `Missing some keys: [...]` (un cookie oublié), `Failed to parse input as JSON`
(collage abîmé), `Login failed: Challenge/Checkpoint/Consent required` (Instagram demande une
vérification — la faire sur le site officiel, puis recommencer).

### Ouvrir un fil Instagram

Les ghosts Instagram sont des **identifiants numériques Meta**, pas des pseudos : `pm <pseudo>`
échoue. `NewConversationSheet` accepte donc les deux écritures — un identifiant numérique part
directement en `pm <id>`, un pseudo passe d'abord par `search <pseudo>`, dont l'app lit la réponse
du bot (`` `17841400000000001` / Malo ``) pour en tirer l'ID.

## 3. Dépannage

Toutes les commandes ci-dessous se lancent depuis `~/correspondance-matrix/` sur le NUC
(`ssh nuc`, puis `cd ~/correspondance-matrix`).

```sh
docker-compose ps                        # les 4 services doivent être Up
docker-compose logs -f mautrix-whatsapp  # le journal du pont WhatsApp, en direct
docker-compose logs -f mautrix-meta      # celui d'Instagram
docker-compose logs --tail=200 synapse   # le homeserver
docker-compose restart mautrix-meta      # redémarrer un pont seul
docker-compose up -d                     # tout relancer (idempotent)
```

**Commandes utiles à envoyer au bot WhatsApp** (dans le DM avec `@whatsappbot`, depuis l'app ou
Element ; hors salon de gestion, les préfixer de `!wa`) :

| Commande | Effet |
| --- | --- |
| `help` | liste complète des commandes de la version installée |
| `login qr` | nouveau QR |
| `login phone <numéro>` | code d'appairage |
| `cancel` | annule le login en cours (à faire si un QR traîne) |
| `logout` | déconnecte le compte WhatsApp du pont |
| `ping` | état de la connexion WhatsApp |
| `sync space` / `backfill` | reconstruit les portails / rejoue l'historique |

**Commandes du bot Instagram** (DM avec `@instagrambot`, préfixe `!ig` hors salon de gestion) :

| Commande | Effet |
| --- | --- |
| `help` | liste complète des commandes de la version installée |
| `login` | démarre le flow cookies (un seul flow : pas de nom à préciser) |
| `cancel` | annule le login en cours |
| `logout` | déconnecte le compte Instagram du pont |
| `ping` | état de la connexion |
| `search <pseudo>` | cherche un compte, renvoie `` `id` / Nom `` |
| `start-chat <id>` (alias `pm`) | ouvre un DM vers un **identifiant numérique** |
| `create-group` | crée un groupe à partir du salon courant |

**Réinitialiser un login qui ne marche plus** : `cancel`, puis `logout`, puis `login qr`. Si le pont
reste bloqué, `docker-compose restart mautrix-whatsapp` puis un nouveau `login qr` — le pont
reprend son état depuis Postgres, rien n'est perdu.

**Symptômes fréquents**

| Symptôme | Piste |
| --- | --- |
| Réglages affiche une erreur de transport | le NUC ou Tailscale est tombé : tester `curl …/_matrix/client/versions` |
| Connexion refusée (`M_FORBIDDEN`) | mauvais mot de passe — relire `CREDENTIALS.txt` sur le NUC |
| La feuille QR tourne sans image | le bot n'a pas répondu : `docker-compose logs -f mautrix-whatsapp` |
| QR téléchargé mais vide / erreur 401 | jeton expiré : Déconnecter Matrix puis se reconnecter |
| Fils WhatsApp absents après le scan | backfill en cours ; sinon `sync space` puis `backfill` au bot |
| Titres de conversation en `!salon:…` ou `@whatsapp_lid-…` | le displayname n'est pas encore arrivé ; il se corrige au `/sync` suivant. Les ghosts sont des **LID** depuis v26.08 : aucun numéro n'est déductible d'un MXID |
| Instagram : « Missing some keys » | un des cinq cookies obligatoires manque — relire `sessionid`, `csrftoken`, `ds_user_id`, `mid`, `ig_did` |
| Instagram : « Challenge/Checkpoint required » | Meta veut une vérification : la faire sur instagram.com, puis relancer `login` |
| Instagram : « Got logged out immediately » | cookies périmés (déconnexion côté navigateur) — se reconnecter sur instagram.com et recopier |
| Instagram : aucun avatar dans l'inbox | attendu : Instagram n'expose pas de numéro, donc rien à rapprocher du carnet d'adresses. Les initiales font office |
| `mautrix-meta` redémarre en boucle | l'entrypoint de l'image `ig-` est court-circuité par le compose ; vérifier que le service garde bien `entrypoint: [/usr/bin/mautrix-instagram, …]` |

**Ne jamais** passer une image mautrix en `latest` sans relire le code : le passage aux ghosts LID
en v26.08 a changé le format des MXID que le client analyse, et la même version a sorti Instagram
de `mautrix-meta`. Côté Instagram, penser aussi au préfixe : `ig-v26.08`, jamais `v26.08`.

## 4. Migrer vers un VPS

Le NUC est un point de départ, pas une fin : il faut que la machine soit joignable pour recevoir les
messages. Le déménagement vers un VPS ne change rien au code Swift — seule l'URL du homeserver bouge.

1. **Nom de domaine** : choisir un vrai `server_name` (`matrix.exemple.fr`) plutôt que
   `correspondance.local`. Attention : `server_name` **n'est pas renommable** après coup ; le plus
   simple est de repartir d'une pile neuve et de relier WhatsApp à nouveau (`login qr`), quitte à
   perdre l'historique déjà bridgé.
2. **Provisionner** le VPS (Debian 12, Docker), puis rejouer l'infra :
   `SSH_HOST=vps SERVER_NAME=matrix.exemple.fr SYNAPSE_BIND_IP=127.0.0.1 SYNAPSE_PUBLIC_IP=<ip> ./infra/matrix/bootstrap.sh`
3. **TLS** : sur un VPS les ports 80/443 sont libres — mettre Caddy ou nginx devant Synapse
   (`reverse_proxy 127.0.0.1:8008`), certificat Let's Encrypt, et servir
   `/.well-known/matrix/server` + `/.well-known/matrix/client`. Le homeserver devient alors
   `https://matrix.exemple.fr` dans Réglages. Ne jamais exposer 8008 en clair sur Internet.
4. **Ou garder Tailscale** : installer tailscale sur le VPS et continuer à joindre le homeserver par
   son IP 100.x. Zéro TLS à gérer, zéro port ouvert — c'est l'option la plus sobre tant que
   Correspondance reste mono-utilisateur.
5. **Reprendre les données** (si on garde le même `server_name`) : arrêter la pile, `pg_dump` de
   Postgres, copier `data/synapse`, `data/mautrix-whatsapp` et `data/mautrix-meta`, restaurer côté
   VPS, relancer. Les ponts reprennent leur session sans rescanner ni recoller de cookies.
6. Côté Mac : Réglages › Matrix › Déconnecter, puis se reconnecter sur la nouvelle URL.
