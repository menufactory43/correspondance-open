---
status: accepted
date: 2026-08-31
---

# Le Relais est la source de vérité ; les appareils sont des clients Matrix

Correspondance existe sur Mac et, bientôt, sur iPhone. Les conversations des réseaux bridgés (WhatsApp, Instagram, Signal) transitent déjà par un homeserver Matrix privé que l'utilisateur possède (le **Relais**, aujourd'hui Synapse sur un NUC joint par Tailscale). Nous décidons que **l'état de conversation** — archivé, épinglé, muet, contacts fusionnés, brouillons — vit lui aussi dans le Relais (room tags, push rules, account data Matrix), et non plus dans le stockage local de chaque appareil. Tout appareil est un client Matrix : il lit les mêmes conversations et le même état, sans synchronisation propre à Correspondance.

## Considered options

- **iCloud (KVS / CloudKit)** pour l'état : zéro serveur, mais l'état vivrait ailleurs que les conversations, serait invisible à tout client tiers (agents, Element) et n'aurait pas d'identité commune avec les conversations Matrix.
- **Un service de synchronisation maison** sur le NUC : réinvente les room tags et l'account data.

## Consequences

- L'app Mac doit remplacer ses `UserDefaults` d'état par des lectures/écritures Matrix (avec cache local) **avant** la première build iOS, pour que celle-ci ne naisse pas avec un état à migrer.
- Le muet est appliqué côté Relais (push rules) : un salon muet n'émet aucune notification push.
- iMessage, qui ne passe pas par le Relais, garde un état local sur le Mac tant qu'il n'y est pas publié. Ce point est volontairement reporté.
- Le `server_name` Matrix actuel (`correspondance.local`) est gravé dans tous les identifiants ; exposer le Relais sur Internet un jour imposera de le recréer sous un vrai domaine. Risque connu, accepté pour l'instant (accès par Tailscale uniquement).
