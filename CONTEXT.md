# Correspondance

Une inbox de conversations humaines (iMessage, Signal, WhatsApp, Instagram…) pensée comme une file à vider, une conversation à la fois. Ce glossaire fixe les mots du domaine ; il ne décrit pas l'implémentation.

## Language

### Conversations

**Conversation** :
Un fil d'échanges avec une personne ou un groupe sur un réseau donné. Une conversation appartient à un seul réseau.
_Avoid_ : chat, thread, salon, room, fil (réservé à l'affichage des messages)

**Message** :
Un élément d'une conversation : texte, pièce jointe, réaction ou événement de groupe.

**Réseau** :
Le service de messagerie d'origine d'une conversation (iMessage, Signal, WhatsApp, Instagram, Messenger).
_Avoid_ : plateforme, canal, intégration, protocole

**Compte lié** :
L'identité de l'utilisateur sur un réseau, connectée à Correspondance (par QR, session web ou appareil lié).
_Avoid_ : compte, login, session

**Contact fusionné** :
Une même personne reconnue sur plusieurs réseaux ; ses conversations sont présentées comme une seule ligne. La fusion est une décision de l'utilisateur, jamais automatique sans confirmation.
_Avoid_ : merged chat, contact unifié, doublon

### Traitement

**File** :
L'ensemble des conversations qui attendent une action de l'utilisateur. L'inbox est une file, pas un salon permanent.
_Avoid_ : inbox (le mode d'affichage), liste, boîte

**Focus** :
Le mode d'affichage par défaut : une seule conversation de la file, avec suivante / précédente / archiver.

**Inbox** :
Le mode d'affichage liste + fil, pour balayer, chercher, multitâcher. Un mode, pas la file elle-même.

**Archiver** :
Sortir une conversation de la file parce qu'elle est traitée. Elle revient dans la file si un nouveau message arrive.
_Avoid_ : supprimer, masquer, fermer, low priority

**Épingler** :
Garder une conversation en tête de file. Une conversation épinglée ne s'archive pas.

**Muet** :
Une conversation qui reste dans la file mais ne notifie pas.

**Rappel** :
Une conversation que l'utilisateur a mise de côté jusqu'à une heure donnée ; elle revient dans la file à cette heure si personne n'a répondu entre-temps.
_Avoid_ : snooze, remind later, reporter

**Demande** :
Une conversation entrante d'un inconnu, tenue hors de la file tant que l'utilisateur ne l'a pas acceptée.
_Avoid_ : message request, inconnu, spam

**État de conversation** :
Ce que l'utilisateur a décidé à propos d'une conversation — archivée, épinglée, muette, fusionnée, brouillon en cours. Cet état appartient à l'utilisateur, pas au réseau, et est le même sur tous ses appareils.
_Avoid_ : préférences, flags, métadonnées

### Infrastructure vue du domaine

**Relais** :
Le serveur, possédé par l'utilisateur, par lequel transitent les conversations des réseaux bridgés et où vit l'état de conversation. Il est toujours allumé.
_Avoid_ : homeserver, Synapse, NUC, serveur, cloud, backend

**Pont** :
Le composant qui relie un réseau au relais. Un pont par réseau et par compte lié.
_Avoid_ : bridge, connecteur, intégration, adaptateur

**Appareil** :
Un Mac ou un iPhone sur lequel Correspondance est installé et connecté au relais. Tous les appareils voient les mêmes conversations bridgées et le même état de conversation.
_Avoid_ : client, device, instance
