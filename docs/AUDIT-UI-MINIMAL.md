# Ce qu'on prend d'iA Writer et des apps du genre — audit du 4 septembre 2026

Trois recensements sur sources primaires (ia.net, ulysses.app, bear.app, typora.io,
getdrafts.com, craft.do, paper.pro, obsidian.md ; superhuman.com, hey.com,
mimestream.com, beeper.com, culturedcode.com), croisés avec ce que Correspondance
fait déjà. Un fait n'est retenu que s'il a une URL officielle ; ce qui ne vient
que de tiers est marqué *(tiers)*. Le précédent audit (`IA-WRITER-PARITY.md`,
bundle local d'iA Writer 8.0.6) reste valable pour les polices et les réglages.

Règle de lecture : **ce qu'on a déjà** n'est pas relisté, sauf quand la source
dit précisément où on s'en écarte.

## Ce qu'on a déjà, et d'où ça vient

| Chez nous | Chez eux |
|---|---|
| Focus = une conversation, chrome fantôme, barre rappelée par la lisière haute ou en remontant le fil | iA Writer : Toolbar/Titlebar « fades in/out », rappelées seulement par survol de leur zone *(tiers pour le déclencheur)* — https://ia.net/writer/support/basics/settings |
| Atténuation du fil à 0,34 pendant la frappe, chrome effacé | iA Writer Focus « paragraph » : le reste « goes gray » ; « once you start typing, iA Writer removes menus and window dressing » — https://ia.net/writer/support/editor/focus-mode/focus-mode-mac |
| Mono / Duo / Quattro / Plex, échelle ⌘+ ⌘- ⌘0 | iA Writer, mêmes familles OFL — https://ia.net/topics/in-search-of-the-perfect-writing-font |
| ⌘Entrée envoie et archive ; la file avance | Superhuman « Send & Mark Done » ⌘⇧Entrée — https://download.superhuman.com/Superhuman%20Keyboard%20Shortcuts.pdf |
| Annuler l'envoi 0/3/5/10 s | HEY `q`, Apple Mail 10 s |
| Envoyer plus tard ⌘⇧L | Superhuman ⌘⇧L, Beeper Send Later |
| Filtres Non-lus / Sans réponse / Brouillons / Programmés | Beeper Unread / Unanswered / Drafts ; Superhuman « No Reply » ⇧R |
| Rappels, fil endormi | Beeper Reminders, HEY Bubble Up, Superhuman Remind Me |
| Demandes (premier contact inconnu mis à part) | HEY Screener — https://help.hey.com/article/722-the-screener |
| Incognito | Texts « Stealth Mode », Beeper « Don't mark as read after archive » |
| ⌘K feuille de garde, ⌘↑ ⌘↓ suivante/précédente, compteur « 3 sur 12 » | Bear/Obsidian Quick Open ⌘O ; Ulysses ⌥⌘↑/↓ ; iA Writer ⌃⌘←/→ |

## Ce qu'on prend

Classé par rapport effet / coût. Chaque ligne dit le comportement exact chez
eux, et ce qu'on en fait ici.

### Pour la page Focus

1. **La largeur en caractères, pas en points** *(fait le 5 septembre : Réglages › Apparence › Longueur de ligne, `ThemePreferences.letterWidth(bodySize:)`)* — iA Writer : « maximum
   characters per line (64, 72 or 80) » (https://ia.net/writer/support/basics/settings) ;
   Drafts idem, « especially useful for full-screen mode ». Chez nous
   `LayoutMetrics.letterWidth = 560` pt, indépendant de la police et de
   l'échelle : à ⌘+ la ligne rétrécit en caractères. → Colonne = N × chasse de
   la police au corps courant, N = 64 par défaut, 72 et 80 dans Réglages ›
   Apparence. Petit.

2. **L'encre dit ce qui est nouveau** *(fait le 5 septembre : `FocusTranscriptView.settleInk`, sur la page de l'inbox seulement)* — HEY : « emails you haven't read yet
   are grouped at the top in New For You… emails you've seen… in Previously
   Seen » (https://www.hey.com/features/the-imbox/) ; iA Writer Authorship :
   le texte humain « in subtle tones », le reste estompé
   (https://ia.net/writer/support/editor/authorship?tab=mac). Chez nous, en
   Focus, rien ne distingue ce qu'on avait lu de ce qui vient d'arriver ; le
   store connaît `unreadAtSelection`. → Les paragraphes déjà lus à l'ouverture
   en `inkSecondary`, les nouveaux en encre pleine ; rien d'autre. Petit.

3. **Après « fini », où va-t-on** — Superhuman Auto-Advance, trois réglages :
   plus ancienne (débit élevé), plus récente (latence stable), retour liste
   (https://new.superhuman.com/customize-auto-advance-105068). Chez nous,
   archiver sélectionne `activeQueue.first`, c'est-à-dire **la plus récente**,
   alors que ⌘↓ va vers la plus ancienne : la file se lit dans un sens et
   s'archive dans l'autre. → Après archivage, la suivante **dans le sens de
   lecture** (rang + 1, sinon rang − 1) ; un réglage à trois crans si on veut
   l'autre. Petit, et c'est une correction.

4. **Trois sorties, jamais quatre** — Superhuman : aujourd'hui (J), un autre
   jour (H), fini (E) ; HEY Power Through : Reply / Reply Later / Set Aside
   (https://updates.37signals.com/post/new-in-hey-power-through-new). Chez
   nous la barre fantôme porte ‹ › puis Résumer, Archiver et le menu. → La
   barre fantôme = ‹ › · **Plus tard** (rappel) · **Fini** (archiver) ; Résumer
   reste conditionnel ; le reste dans le menu contextuel. Petit.

5. **Rappel « si pas de réponse »** — Superhuman Remind Me : par défaut
   « if no reply », Tab pour « regardless », annulé automatiquement à la
   première réponse (https://new.superhuman.com/remind-me-regardless-30768) ;
   Automatic Reminders « if you don't hear back »
   (https://new.superhuman.com/automatic-reminders-306107). Chez nous les
   rappels existent, mais pas liés à l'envoi. → Dans le tiroir « + » du
   composer, « Me rappeler si pas de réponse d'ici demain » ; le rappel se
   pose sur le fil à l'envoi et s'efface au premier message reçu. Moyen.

6. **Historique ⌘[ ⌘]** — Ulysses, Bear, Craft, Obsidian ont tous
   précédent/suivant *dans l'historique*, distinct de la file
   (https://help.ulysses.app/en_US/general/keyboard-shortcuts-mac-ipad).
   Chez nous, après un saut par ⌘K, rien ne ramène là d'où on vient. →
   Une pile de sélection, ⌘[ pour revenir, ⌘] pour ravancer. Petit.

7. **La fin de file comme page** — Superhuman : « Your inbox is off to a
   fresh start », chrome masqué, photo plein écran
   (https://blog.superhuman.com/how-superhuman-chooses-inbox-zero-images/).
   Chez nous : « Rien à lire pour l'instant. » et deux lignes d'état. → Pas
   de photo. Une page blanche datée, « Tout est lu. », le compte de la
   journée en encre tertiaire, et les états de connexion seulement s'il y a
   un problème. Petit.

8. **La stat au survol, une seule à la fois** — iA Writer : une stat dans la
   barre du bas, clic pour en changer, calculée sur la sélection
   (https://ia.net/writer/support/editor/stats?tab=mac) ; Typora : compteur
   « shown when user hover on the titlebar »
   (https://support.typora.io/Word-Count/). → Le compteur « 3 sur 12 » vit
   déjà sous le nom ; s'il gêne, il rejoint la barre fantôme et n'apparaît
   qu'au survol. Décision de goût, à trancher à l'usage.

### Pour le mode Inbox

9. **Deux sections au lieu d'un compteur** — HEY : New For You / Previously
   Seen ; un fil remonte quand un message arrive, descend quand on l'a vu ;
   « Mark Seen » depuis l'avatar (https://www.hey.com/features/the-imbox/).
   Chez nous : une liste « Récents » triée par date, pastille rouge par ligne.
   → La liste se coupe en « Nouveau » (non-lus, en haut) et « Vu » ; la
   pastille disparaît, la section suffit ; clic sur l'avatar = vu sans
   ouvrir. Moyen. C'est le plus grand pas vers le calme de la liste.

10. **Densité de liste réglable** — Mimestream : Dense / Compact / Default /
    Expanded (https://mimestream.com/help/user-guide/list-style) ; Ulysses :
    aperçu de 1 à 6 lignes ; iA Writer 8 : « Compact Library » sans dates ni
    extraits (https://ia.net/topics/search-to-navigate). Chez nous : deux
    lignes d'aperçu, fixe. → Réglages › Apparence › Liste : sans aperçu,
    une ligne, deux lignes. Petit.

11. **Archiver tout ce qui est lu** — Beeper ⌘⇧E
    (https://blog.beeper.com/2023/08/17/power-moves-beepers-keyboard-shortcuts/) ;
    Superhuman « Get Me To Zero ». Chez nous ⌘E archive un fil. → ⌘⇧E dans le
    menu Conversation, avec confirmation par le nombre. Petit.

12. **⌘K vide montre les récents** — Beeper ⌘K « affiche aussi les chats
    récents », Bear/Obsidian Quick Open vide = récents. Chez nous la feuille
    de garde vide montre la file dans l'ordre. → Vide : les cinq derniers
    fils ouverts (la pile de l'idée 6), puis la file. Petit.

13. **Ignorer un fil sans l'archiver** — HEY Ignore a Thread : « replies
    won't show up as new emails anymore… still gets added to the thread's
    page » (https://help.hey.com/article/769-ignore-a-thread). Chez nous
    « endormir » passe par un rappel daté. → Un cran « jusqu'à ce que je
    l'ouvre » dans le rappel, pour les groupes bavards. Petit.

### Pour les deux

14. **Une seule bascule de chrome, et le nombre de volets** — Ulysses ⌘.
    cache tout, « even the window control buttons » ; ⌘1/⌘2/⌘3 = trois, deux,
    un volet, les volets revenant en overlay
    (https://help.ulysses.app/en_US/getting-started/first-steps-library-editor).
    Chez nous ⌘1…⌘4 servent aux réseaux et ⌘⇧O bascule Focus. → Rien à
    changer aux touches ; mais en Focus, la liste pourrait revenir **en
    overlay** au survol de la lisière gauche, sans quitter le mode, comme le
    volet d'Ulysses en éditeur seul. Moyen ; à essayer en maquette avant.

15. **Le curseur ne recentre qu'à la frappe** — Ulysses Fixed Scrolling
    « variable » : souris et flèches libèrent, la ligne ne se fixe qu'à la
    frappe (https://help.ulysses.app/dive-into-editing/editor-customization-guide) ;
    Bear/Lettera : ligne réglable 25–75 % de la hauteur, « the usual
    implementations are subtly wrong »
    (https://community.bear.app/t/typewriter-mode-fans-assemble-and-share-your-insights/19649).
    On a essayé une ligne de lecture à 60 % et on l'a retirée : la page finie
    se lit avec sa réponse en bas. Si on y revient un jour, c'est sous cette
    forme-là — seulement pendant la frappe d'un long message, jamais au repos.

## Ce qu'on ne prend pas, et pourquoi

- **Syntax Highlight, Style Check** (iA Writer) : marquer les adverbes d'un
  ami, non. Déjà écarté dans `IA-WRITER-PARITY.md`.
- **Photo d'Inbox Zero, série hebdomadaire** (Superhuman) : une récompense de
  jeu dans une app qui promet le calme.
- **J/K, G puis lettre** (Superhuman, HEY) : des touches Vim dans une app
  Mac ; ⌘↑/⌘↓ et ⌘K suffisent.
- **Snippets, Instant Reply** (Superhuman) : la réponse mécanique est
  l'inverse du fil qu'on écrit ; la carte de proposition de l'agent couvre
  le cas où on veut de l'aide.
- **Low Priority, Feed, Paper Trail** (Beeper, HEY) : deux poubelles = deux
  décisions ; l'archive et les demandes suffisent. Déjà écarté.
- **Sons de frappe** (Paper), **Content Blocks, hashtags, wikilinks**
  (iA Writer) : un document, pas une conversation.
- **Typewriter au repos** : essayé le 4 septembre, retiré le jour même.

## Ordre proposé

Petits et nets : 3 (sens de la file après archivage), 1 (largeur en
caractères), 2 (encre des non-lus), 4 (trois sorties), 6 + 12 (historique et
récents dans ⌘K), 11 (⌘⇧E), 7 (fin de file). Puis 9 (deux sections en
Inbox) et 10 (densité), qui changent la liste. Puis 5 (rappel si pas de
réponse) et 13. Le 14 attend une maquette.

## Sources

Rapports complets des trois recensements : iA Writer
(https://ia.net/writer/support), apps d'écriture (Ulysses, Bear, Typora,
Drafts, Craft, Paper, Obsidian), inbox épurées (Superhuman, HEY, Mimestream,
Beeper, Texts, Things 3). Les URL de chaque fait sont données en ligne
ci-dessus ; ce qui n'a pas de source officielle est marqué *(tiers)* ou n'est
pas cité. Non trouvé nulle part : l'opacité exacte de l'atténuation d'iA
Writer et d'Ulysses (Typora : `#C8C8C8` ; plugin Typewriter Mode d'Obsidian :
0,25 — la nôtre est 0,34).
