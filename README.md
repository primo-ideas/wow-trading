# wow-market

Courbes de prix et informations sur l'hôtel des ventes de World of Warcraft.

- [`fetcher/`](fetcher/) : récupère les enchères sur l'API Battle.net et stocke des statistiques de prix (Rust).
- `web/` : le site, à venir (Rails). Il lira la base remplie par le fetcher.

## Essayer sans identifiants

```sh
cargo test
cargo run -p wow-market-fetcher -- once --stub
```

`--stub` sert des données d'exemple intégrées au lieu d'appeler Battle.net, et écrit dans `data/stub.sqlite3` : les fausses données ne peuvent pas se mélanger à l'historique réel.

## Brancher Battle.net

1. Créer un client sur <https://develop.battle.net/access/clients>.
2. Copier `.env.example` vers `.env` et renseigner `BLIZZARD_CLIENT_ID` et `BLIZZARD_CLIENT_SECRET`. Ce fichier est ignoré par git.
3. Lancer un cycle, puis laisser tourner :

```sh
cargo run -p wow-market-fetcher -- once    # un cycle, code de sortie non nul si un marché a échoué
cargo run -p wow-market-fetcher -- watch   # un cycle toutes les 10 minutes, jusqu'à Ctrl-C
```

Les données vont dans `data/wow_market.sqlite3`. Sans `--stub` et sans identifiants, le programme s'arrête avec un message d'erreur : il ne se rabat jamais sur les données d'exemple.

## Configuration

Chaque option peut se passer en ligne de commande ou dans `.env`.

| Option | Variable | Défaut | Rôle |
| --- | --- | --- | --- |
| `--region` | `WOW_REGION` | `eu` | `us`, `eu`, `kr` ou `tw` |
| `--locale` | `WOW_LOCALE` | `fr_FR` | Langue des noms d'objets et de royaumes |
| `--realms` | `WOW_REALMS` | vide | Royaumes suivis : slugs séparés par des virgules, ou `all`. Vide : matières premières seulement, toujours suivies |
| `--concurrency` | `WOW_CONCURRENCY` | `4` | Requêtes simultanées |
| `--item-batch` | `WOW_ITEM_BATCH` | `500` | Objets à identifier au maximum par cycle |
| `--poll-seconds` (`watch`) | `WOW_POLL_SECONDS` | `600` | Attente entre deux cycles |
| `--database` | | voir plus haut | Fichier SQLite |

Les logs se règlent avec `RUST_LOG`, par exemple `RUST_LOG=debug`.

## Fonctionnement

À chaque cycle, le fetcher :

1. découvre les royaumes connectés encore inconnus ;
2. demande à chaque marché suivi son snapshot avec `If-Modified-Since`, ce qui ne coûte presque rien tant que rien n'a changé ;
3. réduit chaque nouveau snapshot à une ligne de statistiques par objet, écrite en une seule transaction ;
4. récupère les noms et caractéristiques des objets nouvellement vus, par lots.

Un marché en échec n'empêche pas les autres et sera retenté au cycle suivant. Des identifiants refusés arrêtent le programme, car réessayer n'y changerait rien.

## Données

Les prix sont en pièces de cuivre (1 po = 10 000) et les dates en secondes Unix UTC.

| Table | Contenu |
| --- | --- |
| `auction_houses` | Un marché : un royaume connecté, ou les matières premières de la région (`connected_realm_id` à `NULL`) |
| `realms` | Royaumes et marché auquel chacun appartient |
| `snapshots` | Journal des snapshots ingérés |
| `price_points` | Prix minimum, 1er quartile, médiane, 3e quartile, moyenne, quantité et nombre d'enchères, par objet et par snapshot |
| `items` | Nom, qualité, niveau et classe des objets. `name` à `NULL` : pas encore identifié, ou inconnu de l'API |

Les quantiles sont pondérés par la quantité, pour qu'une annonce unique à un prix absurde ne déplace pas la médiane. Préférer la médiane ou les quartiles à la moyenne pour les courbes : la moyenne reste sensible à ces annonces.

`variant` distingue ce qui partage un même identifiant d'objet sans être le même produit :

| `variant` | Sens |
| --- | --- |
| *(vide)* | Objet simple |
| `pet:39` | Mascotte en cage, par espèce : toutes partagent l'objet 82800 |
| `bonus:1472,6652` | Équipement, par liste de bonus, qui détermine notamment le niveau d'objet |

Une courbe se lit directement :

```sql
SELECT taken_at, min_price, median_price, quantity
FROM price_points
WHERE auction_house_id = ? AND item_id = ? AND variant = ''
ORDER BY taken_at;
```

Le schéma appartient au fetcher, qui l'applique lui-même au démarrage depuis [`fetcher/migrations/`](fetcher/migrations/). Le site doit traiter ces tables en lecture seule et ne pas les migrer. SQLite est en mode WAL : le site peut lire pendant une ingestion.

## Volume

Mesures sur des données synthétiques : 20 000 séries par snapshot (une hypothèse, le vrai nombre reste à observer), en build release.

| Historique du marché | Écriture d'un snapshot |
| --- | --- |
| Aucun | 58 ms |
| 1 jour | 430 ms |
| 10 jours | 3,9 s, avec un pic isolé à 69 s |

Le stockage est de 44 octets par ligne, soit environ 21 Mo par jour et par marché, ou 7,7 Go par an, avec un snapshot par heure.

Avec `WOW_REALMS=all`, ces chiffres se multiplient par le nombre de royaumes connectés de la région. À cette échelle, il faudra purger l'historique ou passer à Postgres ; tout le SQL se trouve dans [`store.rs`](fetcher/src/store.rs) et les migrations.

## Limites connues

- Les fixtures ont été écrites à la main : le format réel des réponses ne sera confirmé qu'au premier lancement avec de vrais identifiants.
- Les enchères individuelles ne sont pas conservées, seulement les statistiques. On ne peut donc ni recalculer l'historique avec d'autres statistiques, ni estimer les ventes.
- Pas de purge ni d'agrégation de l'historique ancien.
- Pas de noms de mascottes ni d'icônes d'objets, qui demandent d'autres appels API.
- Les `modifiers` d'objets ne font pas partie de `variant`.
- Ni la Chine, qui utilise d'autres serveurs, ni WoW Classic.
