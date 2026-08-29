# Matrix & WhatsApp — installation, usage, dépannage

Correspondance parle WhatsApp par un pont : un homeserver **Synapse** privé et le bridge
**mautrix-whatsapp**, tous deux sur le NUC, joints depuis le Mac par Tailscale. iMessage et Signal
restent natifs et ne passent pas par là.

```
Mac (Correspondance) ──Tailscale──► Synapse 100.64.0.7:8008 ──► mautrix-whatsapp ──► WhatsApp
```

## 0. Ce qui tourne déjà, et où

Sur le NUC (`ssh nuc`, user `meff`, **pas de sudo**, `docker-compose` 1.29 — jamais `docker compose`) :

| Conteneur | Image | Rôle |
| --- | --- | --- |
| `correspondance-synapse` | `matrixdotorg/synapse` | homeserver, `server_name: correspondance.local` |
| `correspondance-postgres` | `postgres:16-alpine` | base de Synapse et du bridge |
| `correspondance-mautrix-whatsapp` | `dock.mau.dev/mautrix/whatsapp:v26.08` | pont WhatsApp (tag **épinglé**) |

Tout vit dans `~/correspondance-matrix/` : configs générées, données, et `CREDENTIALS.txt`
(chmod 600) qui contient le mot de passe du compte `@meffysto:correspondance.local`. Ce fichier ne
quitte jamais le NUC et n'est pas versionné.

Les sources d'infra sont dans `infra/matrix/` (compose, templates, `bootstrap.sh`). Le script est
idempotent : `./infra/matrix/bootstrap.sh` depuis le Mac recopie et réapplique tout sans dégât.

### Pourquoi `127.0.0.1:8008` mais un accès en `100.64.0.7:8008`

Tailscale tourne sur le NUC en **userspace-networking** : il n'y a aucune interface `tailscale0`,
donc l'IP `100.64.0.7` n'est pas assignable en `bind`. `tailscaled` relaie lui-même le trafic
entrant du tailnet vers le `127.0.0.1` de l'hôte. Synapse écoute donc en loopback
(`ports: 127.0.0.1:8008->8008`) et reste joignable depuis n'importe quelle machine du tailnet en
`http://100.64.0.7:8008`, sans jamais être exposé sur le LAN 192.168. C'est voulu : ne pas
« corriger » ce bind en `0.0.0.0`.

Vérification depuis le Mac :

```sh
curl -s http://100.64.0.7:8008/_matrix/client/versions | head -c 120
```

## 1. Connexion dans l'app

**Correspondance › Réglages › Matrix** :

1. **Homeserver** : `http://100.64.0.7:8008` (pré-rempli).
2. **Identifiant** : `meffysto` (pré-rempli). Le MXID complet est `@meffysto:correspondance.local`.
3. **Mot de passe** : celui de `~/correspondance-matrix/CREDENTIALS.txt` sur le NUC.
4. **Connexion**. L'app ping d'abord le homeserver — un mot de passe n'est jamais envoyé à une
   mauvaise adresse.

Le jeton d'accès part dans le **Trousseau** (jamais dans UserDefaults, jamais dans le repo). La
ligne « État » affiche ensuite le MXID connecté et le nombre de fils WhatsApp. **Déconnecter
Matrix** révoque le jeton côté serveur, vide le Trousseau et le cache disque des conversations.

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
pointé sur `http://100.64.0.7:8008` fait très bien l'affaire pour dialoguer avec le bot.

### Ouvrir un fil vers un numéro

`NewConversationSheet` (WhatsApp sélectionnable seulement si Matrix est connecté) envoie au bot la
commande `pm +33612345678`. Le bot crée le portail et le salon arrive au `/sync` suivant.

## 3. Dépannage

Toutes les commandes ci-dessous se lancent depuis `~/correspondance-matrix/` sur le NUC
(`ssh nuc`, puis `cd ~/correspondance-matrix`).

```sh
docker-compose ps                        # les 3 services doivent être Up
docker-compose logs -f mautrix-whatsapp  # le journal du pont, en direct
docker-compose logs --tail=200 synapse   # le homeserver
docker-compose restart mautrix-whatsapp  # redémarrer le pont seul
docker-compose up -d                     # tout relancer (idempotent)
```

**Commandes utiles à envoyer au bot** (dans le DM avec `@whatsappbot`, depuis l'app ou Element) :

| Commande | Effet |
| --- | --- |
| `help` | liste complète des commandes de la version installée |
| `login qr` | nouveau QR |
| `login phone <numéro>` | code d'appairage |
| `cancel` | annule le login en cours (à faire si un QR traîne) |
| `logout` | déconnecte le compte WhatsApp du pont |
| `ping` | état de la connexion WhatsApp |
| `sync space` / `backfill` | reconstruit les portails / rejoue l'historique |

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

**Ne jamais** passer l'image mautrix en `latest` sans relire le code : le passage aux ghosts LID en
v26.08 a changé le format des MXID que le client analyse.

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
   Postgres, copier les volumes `synapse-data` et `whatsapp-data`, restaurer côté VPS, relancer.
   Le pont reprend sa session WhatsApp sans rescanner.
6. Côté Mac : Réglages › Matrix › Déconnecter, puis se reconnecter sur la nouvelle URL.
