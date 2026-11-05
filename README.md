# wow-market

Courbes de prix et ventes estimées de l'hôtel des ventes de World of Warcraft.

- [`fetcher/`](fetcher/) : récupère les enchères sur l'API Battle.net et stocke des statistiques dans Postgres (Rust).
- [`web/`](web/) : le site, qui lit cette base sans jamais y écrire (Rails).

## Essayer sans identifiants

Sous Windows, avec [PowerShell 7.2 ou plus](https://github.com/PowerShell/PowerShell) et [Rust](https://rustup.rs) :

```powershell
./run.ps1 -Stub
```

Au premier lancement, le script installe Postgres et Ruby dans `%LOCALAPPDATA%\wow-market`, sans droits d'administrateur, sans toucher au `PATH` et sans créer de service. Il simule ensuite une semaine d'enchères, démarre le site sur <http://127.0.0.1:3000> et ouvre le navigateur. Ctrl-C arrête tout ce qu'il a démarré.

`-Stub` écrit dans une base à part, `wow_market_stub` : les fausses données ne peuvent pas se mélanger à l'historique réel.

## Brancher Battle.net

1. Créer un client sur <https://develop.battle.net/access/clients>.
2. Copier `.env.example` vers `.env` et renseigner `BLIZZARD_CLIENT_ID` et `BLIZZARD_CLIENT_SECRET`. Ce fichier est ignoré par git.
3. Lancer le script sur un petit périmètre :

```powershell
./run.ps1 -Scope eu/commodities
```

Sans `-Scope`, le script récupère tous les royaumes de toutes les régions. Sans `-Stub` et sans identifiants, il s'arrête avec un message d'erreur : il ne se rabat jamais sur les données d'exemple.

## run.ps1

| Option | Rôle |
| --- | --- |
| `-Scope` | Ce qu'il faut récupérer, voir [Périmètre](#périmètre) |
| `-Config` | Fichier contenant les identifiants, à la place de `.env` |
| `-Stub` | Données simulées, sans identifiants |
| `-Port` | Port du site, 3000 par défaut |
| `-NoBrowser` | N'ouvre pas le navigateur |
| `-SetupOnly` | Installe ce qui manque, puis s'arrête |
| `-Test` | Lance les tests du fetcher et du site, puis s'arrête |

## Sans run.ps1

Le script ne fonctionne que sous Windows. Ailleurs, avec un serveur Postgres et Ruby déjà installés (ces commandes n'ont pas été testées hors de Windows) :

```sh
export DATABASE_URL=postgres://utilisateur:mot-de-passe@localhost:5432/wow_market
cargo run -p wow-market-fetcher -- --stub once

cd web
bundle install
DATABASE_URL=postgres://utilisateur:mot-de-passe@localhost:5432/wow_market_stub bin/rails server
```

Le fetcher crée la base si elle n'existe pas et applique lui-même ses migrations.

## Fetcher

```sh
cargo run -p wow-market-fetcher -- once    # un cycle, code de sortie 2 si un marché a échoué
cargo run -p wow-market-fetcher -- watch   # un cycle toutes les 10 minutes, jusqu'à Ctrl-C
```

Chaque option peut se passer en ligne de commande ou par une variable d'environnement, éventuellement dans `.env`. Une variable déjà présente dans l'environnement l'emporte sur le fichier.

| Option | Variable | Défaut | Rôle |
| --- | --- | --- | --- |
| | `DATABASE_URL` | obligatoire | Serveur et base Postgres |
| | `BLIZZARD_CLIENT_ID`, `BLIZZARD_CLIENT_SECRET` | obligatoires sans `--stub` | Identifiants Battle.net |
| `--scope` | `WOW_SCOPE` | tout | Ce qu'il faut récupérer |
| `--locale` | `WOW_LOCALE` | `fr_FR` | Langue des noms d'objets et de royaumes |
| `--concurrency` | `WOW_CONCURRENCY` | `4` | Requêtes simultanées par région |
| `--item-batch` | `WOW_ITEM_BATCH` | `5000` | Objets à identifier au maximum par cycle |
| `--hourly-retention-days` | `WOW_HOURLY_RETENTION_DAYS` | `14` | Jours de détail horaire conservés |
| `--poll-seconds` (`watch`) | `WOW_POLL_SECONDS` | `600` | Attente entre deux cycles |
| `--config` | | `.env` | Fichier de variables à lire |
| `--stub` | | | Données simulées, dans la base suffixée `_stub` |

Les logs se règlent avec `RUST_LOG`, par exemple `RUST_LOG=debug`.

### Périmètre

Une ou plusieurs entrées séparées par des virgules, par exemple `eu/hyjal,eu/archimonde,us` :

| Entrée | Sens |
| --- | --- |
| `eu` | Tous les royaumes de la région, et ses matières premières |
| `eu/hyjal` | Ce royaume, et les matières premières de la région |
| `eu/commodities` | Les matières premières de la région seulement |

Les régions sont `us`, `eu`, `kr` et `tw`.

### Déroulement d'un cycle

Pour chaque région, le fetcher :

1. découvre les royaumes connectés encore inconnus ;
2. demande à chaque marché suivi son snapshot avec `If-Modified-Since`, ce qui ne coûte presque rien tant que rien n'a changé ;
3. réduit chaque nouveau snapshot à une ligne de statistiques par objet, estime les ventes depuis le snapshot précédent, et écrit le tout en une seule transaction.

Il récupère ensuite les noms et caractéristiques des objets nouvellement vus, par lots, puis résume en statistiques journalières les jours sortis de la période de rétention.

Un marché en échec n'empêche pas les autres et sera retenté au cycle suivant. Des identifiants refusés, un royaume inconnu ou une erreur de base de données arrêtent le programme, car réessayer n'y changerait rien.

## Données

Les prix sont en pièces de cuivre (1 po = 10 000) et les dates en UTC.

| Table | Contenu |
| --- | --- |
| `auction_houses` | Un marché : un royaume connecté, ou les matières premières de la région (`connected_realm_id` à `NULL`) |
| `realms` | Royaumes et marché auquel chacun appartient |
| `snapshots` | Journal des snapshots ingérés |
| `market_states` | Enchères du dernier snapshot de chaque marché, pour estimer les ventes au suivant. Pas destinée à la lecture |
| `price_points` | Prix minimum, 1er quartile, médiane, 3e quartile, moyenne, quantité et nombre d'enchères, par objet et par snapshot |
| `sales_points` | Quantité, valeur et nombre d'enchères vendues, par objet, entre deux snapshots |
| `price_points_daily`, `sales_points_daily` | Les mêmes données, par jour UTC, une fois sorties de la période de rétention |
| `items` | Nom, qualité, niveau et classe des objets. `name` à `NULL` : pas encore identifié, ou inconnu de l'API |

`price_points` et `sales_points` ont une partition par jour. Au-delà de la rétention, chaque jour est remplacé par une ligne par objet dans les tables `*_daily` : prix et quantités moyens, prix minimum le plus bas, ventes additionnées. Ce résumé est définitif.

Les quantiles sont pondérés par la quantité, pour qu'une annonce unique à un prix absurde ne déplace pas la médiane. Préférer la médiane ou les quartiles à la moyenne pour les courbes : la moyenne reste sensible à ces annonces.

`variant` distingue ce qui partage un même identifiant d'objet sans être le même produit :

| `variant` | Sens |
| --- | --- |
| *(vide)* | Objet simple |
| `pet:39` | Mascotte en cage, par espèce : toutes partagent l'objet 82800 |
| `bonus:1472,6652` | Équipement, par liste de bonus, qui détermine notamment le niveau d'objet |

Une courbe récente se lit directement ; [`item_history.rb`](web/app/models/item_history.rb) y ajoute les jours résumés.

```sql
SELECT taken_at, min_price, median_price, quantity
FROM price_points
WHERE auction_house_id = $1 AND item_id = $2 AND variant = ''
ORDER BY taken_at;
```

### Ventes estimées

L'API ne donne pas les ventes. Le fetcher compare deux snapshots consécutifs : une enchère qui disparaît compte comme vendue si elle avait trop de temps restant pour avoir simplement expiré, et une quantité qui baisse compte comme une vente partielle.

Cela reste une estimation. Une enchère annulée ressemble à une vente, ce qui gonfle le chiffre. Une enchère vendue peu avant d'expirer, ou mise en vente et vendue entre deux snapshots, passe inaperçue, ce qui le réduit.

## Site

- `/` : les marchés par région, avec une recherche par royaume.
- `/markets/:id` : ce qui est en vente au dernier snapshot, avec une recherche par nom ou identifiant, sans tenir compte des accents ni de la casse.
- `/markets/:id/items/:id` : courbes de prix, ventes estimées et quantité en vente, sur 24 heures, 7, 30 ou 90 jours, ou tout l'historique. Chaque graphique a son tableau de données.

Le schéma appartient au fetcher : le site n'a pas de migrations, et hors tests Postgres refuse ses écritures (`default_transaction_read_only`). Ses tests chargent les migrations du fetcher, donc un changement de schéma qui casse le site les fait échouer. Ils vident leur base et refusent de tourner sur une base dont le nom ne finit pas par `_test`.

## Volume

Le volume n'a pas encore été mesuré sur de vraies données ; il faudra le faire au premier lancement, sur un petit périmètre. Ce qui grossit :

- `price_points` et `sales_points`, de quelques lignes par objet et par snapshot, pendant la rétention ;
- les tables `*_daily` et `snapshots`, qui ne sont jamais purgées.

Le tout se multiplie par le nombre de marchés suivis, soit tous les royaumes connectés des quatre régions par défaut. `run.ps1` avertit quand il reste moins de 20 Go sur le disque.

## Limites connues

- Les fixtures ont été écrites à la main : le format réel des réponses ne sera confirmé qu'au premier lancement avec de vrais identifiants.
- Les enchères individuelles ne sont conservées que jusqu'au snapshot suivant. On ne peut donc pas recalculer l'historique avec d'autres statistiques.
- Pas de noms de mascottes ni d'icônes d'objets, qui demandent d'autres appels API : le site affiche l'espèce ou la liste de bonus.
- Les `modifiers` d'objets ne font pas partie de `variant`.
- Ni la Chine, qui utilise d'autres serveurs, ni WoW Classic.
- Le site est pensé pour un usage local : pas d'authentification, et `run.ps1` ne l'expose que sur `127.0.0.1`. Les heures sont affichées à l'heure de Paris.
