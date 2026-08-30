# Correspondance — freeze produit (pivot inbox)

**Statut :** Mac livré (2026-08-31, reste l’optimisation). Prochain chantier : iOS. Focus = défaut sur Mac ; Inbox = défaut sur iPhone.  
**Révisé le 2026-08-31** : positionnement, iOS, horizon agents/E2EE — voir « Révision iOS » en bas.  
**Supersède :** bureau de lettres / plis / slash Writing-Tools-like (`/réponds` `/thème` `/relis`).

---

## Phrase produit

**Correspondance : une inbox iMessage + Signal — live sous le capot, Focus par défaut (une conversation), et une vue liste normale type Beeper quand tu en as besoin. Tu réponds ici, tu archives.**

Construit pour un usage perso, en interdisant les impasses mono-utilisateur : chaque décision doit rester valable si un tiers installe l’app un jour. Pas de lancement promis.

---

## Pourquoi ce pivot

| Piste abandonnée | Raison |
|------------------|--------|
| Slash IA type `/relis` `/réponds` | Recouvre Apple Writing Tools + iA Writer (WT déjà *dans* iA + Authorship). |
| « Plus beau que Beeper » seul | Beeper (Automattic) a déjà l’inbox unifiée, merged chats, multi-réseaux. Design seul ne tient pas. |
| Agrégateur social (IG/X/…) | Ce n’était pas le besoin : **conversations** (messageries), pas le feed. |

**Écart retenu :** live sous le capot + **UX lente** (Focus + file à traiter), Mac-native, zen — pour *toi*, sur les réseaux que tu ouvres vraiment.

---

## Décisions gelées

### Cœur UX
1. **Live invisible** — sync temps réel pour ne rien rater.
2. **UI par défaut = Focus** — une conversation à la fois.
3. **Vue Inbox (liste normale)** — mode Beeper-like : liste de conversations + fil. Pas secondaire caché : accessible en un clic / raccourci ; Focus reste le démarrage.
4. **File à archiver** — inbox = travail à vider, pas un salon permanent.
5. **Répondre 100 % dans l’app** — pas de deep-link obligatoire vers Messages / Signal pour l’usage quotidien cible.

### Modes d’affichage
| Mode | Rôle |
|------|------|
| **Focus** | Défaut. Une conversation, navigation suivante / précédente / archiver. |
| **Inbox** | Liste + détail (comme Beeper / Mail). Pour balayer, chercher, multitâche. Accessible ⌘2 / toggle chrome — pas un mode caché. |

### Réseaux MVP
| Réseau | Approche | Priorité |
|-------|----------|----------|
| **iMessage** | Local Mac (Messages / store local — détails en spike) | Jour 1 |
| **Signal** | Compte / appareil **lié** (modèle type Signal Desktop / bridge device) | Jour 1 |
| Messenger, Telegram, WhatsApp, etc. | Hors MVP | Plus tard / jamais sauf besoin perso |

Inspiration technique (pas une copie produit) : ce que Beeper fait côté bridges / device-local — on assume le hacky pour un usage perso.

### Hors scope (pour l’instant)
- Génération IA / slash Writing Tools
- Thèmes d’écriture IA
- Rituel pli (reposer → sceller → remettre) comme cœur produit
- Monétisation / store

---

## Code actuel (lettres)

**Reset soft :**
- **Garder** l’esprit design (thèmes, typo, chrome fenêtre, focus zen).
- **Abandonner** le domaine produit plis / Markdown letters / rituels comme job #1.
- Nouveau découpage domaine : conversation, message, compte lié, file Focus, archive — **quand** le go code arrive.
- Soit refactor in-place du shell, soit chantier propre dans le même repo ; pas deux apps.

Le code lettres reste dans le repo comme héritage jusqu’au chantier ; il n’est plus la spec.

---

## Succès dogfood (horizon ~30 jours une fois codé)

Tu ouvres Correspondance le matin : file iMessage + Signal, **une** conversation Focus, tu réponds depuis l’app, tu archives, tu passes à la suivante — sans ouvrir Messages ni Signal pour le flux principal.

---

## Prochaines étapes

1. ~~Shell dual Focus + Inbox~~ (fait)
2. Accorder Full Disk Access → lire le vrai `chat.db` (sinon données démo)
3. Stabiliser envoi iMessage (AppleScript / Automation)
4. Installer + lier `signal-cli`, brancher list/receive
5. Polling live / FSEvents sur chat.db

---

## Anti-objectifs

- Ne pas devenir un Beeper allégé mal connecté.
- Ne pas reconstruire des Writing Tools.
- Ne pas promettre 10 réseaux avant que iMessage + Signal tiennent pour toi.

---

## Révision iOS — 2026-08-31 (session grill)

Glossaire : `CONTEXT.md`. Décision structurante : `docs/adr/0001-relais-source-de-verite.md`.

### Décisions
1. **Positionnement** : perso, sans impasse mono-utilisateur ; produit en horizon, pas de lancement promis.
2. **iPhone = client Matrix pur** (WhatsApp, Instagram, Signal via le Relais). iMessage sur iPhone : reporté, non décidé.
3. **État de conversation partagé** entre appareils, stocké dans le Relais (ADR 0001). À faire sur Mac **avant** la première build iOS.
4. **Structure** : package local `CorrespondanceCore` (Domain, Matrix, stores portables, shim plateforme, tests) + `CorrespondanceUI` (vues partagées) + deux cibles. iMessage, fenêtres, Quick Reply, barre de menus, hotkey, Dictus restent dans la cible Mac. `InboxStore` reste Mac ; l’iOS a son propre store au-dessus de Core.
   Tout le chantier (y compris le code Mac « état dans Matrix ») se fait dans un worktree ; `main` reste l’app quotidienne, intacte jusqu’à la fusion. Une étape = un build vert = un commit, zéro changement de comportement.
5. **Notifications** : Sygnal sur le Relais + APNs dès la v1 ; muet appliqué par push rules côté Relais.
6. **Accès au Relais** : Tailscale sur l’iPhone en v1. URL du Relais = configuration, jamais en dur. Exposition publique = plus tard (impose un vrai `server_name`).
7. **E2EE** : après la v1 iOS, premier chantier de la v2. Règle dès Core : *aucune fonctionnalité ne dépend de la lecture des messages par le Relais* (recherche locale, aperçus côté appareil, push = réveil).
8. **Agents** (Hermes/OpenClaw comme utilisateurs Matrix) : après iOS, avant E2EE. Non modélisés pour l’instant.
9. **UI iPhone** : Inbox (liste) par défaut, Focus accessible depuis la barre du bas. Repère visuel : Beeper iOS. Layout adaptatif dès la v1 (compact = pile, regular = deux colonnes) — obligatoire pour iPhone Fold, offre l’iPad.
10. **Périmètre** : rien n’est hors-scope. v1 = tout ce que le Mac fait, porté. Puis, dans Core pour les deux plateformes, dans l’ordre : filtres (non lus / brouillons / sans réponse / groupes), rappels, demandes, recherche par médias, vocaux + transcription, sondages, GIF, note à soi. Low Priority reste rejeté.
11. **Ordre** : commit de l’arbre → état dans Matrix (Mac) → extraction Core (worktree) → cible iOS vide qui compile → iOS v1 → backlog partagé → agents → E2EE.

### Risques ouverts
- `server_name = correspondance.local` gravé dans les identifiants Matrix.
- Tailscale iOS tombé = app qui ne charge pas (le push arrive quand même).
- Mac 8 Go : Xcode + simulateur serré. `simslim` installé pour itérer sur le simulateur iOS ; on garde actifs `store` (push — indispensable pour Sygnal), `pim` (Contacts), `photos` (sélecteur du composer), `web` (liens universels). `siri` à réactiver pour tester la dictée.
