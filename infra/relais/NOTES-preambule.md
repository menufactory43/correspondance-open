# Correspondance — $TAG

Une release porte **tout le produit** : le Relais, l'agent et l'app. `releases/latest/download`
ne sert que la release la plus récente, donc en publier une moitié rendrait 404 à l'autre.

**Le Relais**, en binaires et sans conteneur : Continuwuity 26.8.1 (macOS arm64, construit par
nous — l'amont ne publie rien pour macOS), les ponts mautrix v0.2608.0 en goolm (WhatsApp,
Signal, Instagram, Messenger ; macOS arm64 et Linux amd64, Signal Linux venant de l'amont),
Tailcat v0.4.0 (macOS arm64) et l'installeur `relais-install.sh`.

**L'agent** (`cc`, `hermes`, …) : un binaire par système, construit avec sa machine crypto — il
sait donc lire un salon chiffré. La tranche Linux est croisée en musl, donc statique : aucune
version de glibc à respecter.

**L'app Mac**, en DMG glisser-déposer, signée et notarisée, ticket agrafé.

Les binaires macOS sont signés Developer ID (meffysto, AKMNXGVVGX), runtime durci,
horodatés, et notarisés par Apple. Un binaire nu ne peut pas être agrafé — `stapler` n'agrafe que
des paquets — donc leur ticket reste en ligne ; le DMG, lui, porte le sien. Les sommes sont dans
`SHA256SUMS`, et l'installeur les vérifie avant de poser quoi que ce soit.

Poser un Relais :

```
curl -fsSLO https://github.com/menufactory43/correspondance-releases/releases/latest/download/relais-install.sh
bash relais-install.sh
```

Poser un agent sur une machine qui a déjà `claude` ou `hermes` :

```
curl -fsSL https://github.com/menufactory43/correspondance-releases/releases/latest/download/install.sh | sh
```
