# Déployer sur un serveur

Pour un petit serveur Ubuntu 26.04, par exemple une instance Scaleway. Un seul script installe tout : Postgres, le fetcher et son timer, le site, et Caddy pour le HTTPS si tu donnes un domaine.

> **Pas encore testé sur un vrai serveur.** Le site a tourné en mode production et le fetcher sur la vraie API, mais sous Windows. `install.sh` et les unités systemd n'ont jamais été exécutés sous Linux, faute d'y avoir accès pendant le développement. Il est écrit pour pouvoir être relancé sans risque : en cas d'échec, corrige la cause et relance-le.

## Installer

Prévois une vingtaine de Go de disque pour les matières premières et un royaume, compilation comprise. Le dépôt doit être accessible depuis le serveur.

```sh
git clone <url-du-dépôt> wow-market
cd wow-market
sudo SCOPE=eu/commodities,eu/hyjal ./deploy/install.sh
```

Compter plusieurs minutes : le fetcher se compile sur place. Le script ajoute 2 Go de swap si le serveur a moins de 4 Go de mémoire et pas de swap, et limite les compilations simultanées.

Il s'arrête ensuite en demandant les identifiants Battle.net :

1. Crée un client sur <https://develop.battle.net/access/clients>.
2. Renseigne `BLIZZARD_CLIENT_ID` et `BLIZZARD_CLIENT_SECRET`, sans guillemets :

   ```sh
   sudo nano /etc/wow-market/fetcher.env
   ```

3. Démarre, puis vérifie :

   ```sh
   sudo systemctl enable --now wow-market-fetcher.timer
   sudo systemctl start --no-block wow-market-fetcher.service
   sudo ./deploy/check.sh
   ```

`check.sh` dit ce qui va et ce qui ne va pas, et n'affiche aucun secret : sa sortie peut se partager pour demander de l'aide.

### Voir le site

Par défaut, le site n'écoute que sur le serveur. Depuis ton ordinateur, passe par un tunnel SSH puis ouvre <http://127.0.0.1:3000> :

```sh
ssh -L 3000:127.0.0.1:3000 <serveur>
```

Pour le rendre public, fais pointer le DNS du domaine vers le serveur, ouvre les ports 80 et 443 dans son groupe de sécurité Scaleway, puis relance le script. Caddy obtient et renouvelle seul le certificat :

```sh
sudo DOMAIN=market.example.com ./deploy/install.sh
```

Le site n'a pas d'authentification : une fois public, n'importe qui peut le lire. Il ne peut pas modifier la base, son rôle Postgres n'ayant que le droit de lecture.

## Quand le fetcher tourne

**Un timer systemd, toutes les 5 minutes.**

Blizzard publie une fois par heure. Le 5 novembre 2026, les 93 marchés européens ont tous changé en même temps, à 10:21:54, 11:21:53 puis 12:21:53 UTC. Ce sont peu de mesures : un seul jour, une seule région.

- **Pourquoi pas une seule fois par heure, à la bonne minute :** rien ne garantit que cette minute reste la même, ni qu'elle soit la même dans les autres régions. Une minute décalée ferait perdre une heure de données.
- **Pourquoi demander souvent ne coûte rien :** chaque demande porte `If-Modified-Since`, et Blizzard répond 304 sans données tant que rien n'a changé. Les nouveaux relevés arrivent ainsi moins de 5 minutes après leur publication.
- **Pourquoi pas plus souvent :** les données ne changent pas plus vite. Et chaque cycle identifie jusqu'à 1 000 nouveaux objets, soit 2 000 requêtes : à 5 minutes, cela reste sous la limite de 36 000 requêtes par heure de Battle.net.
- **Pourquoi systemd plutôt que cron :** un cycle encore en cours n'est pas relancé par-dessus lui-même, les logs vont dans le journal, l'ordre de démarrage avec Postgres est géré, et le fetcher tourne sans aucun droit au-delà du réseau et de sa base.

Pour changer l'intervalle, relance le script :

```sh
sudo POLL_MINUTES=10 ./deploy/install.sh
```

## Dimensionner le serveur

Ces chiffres viennent de vrais relevés d'`eu/commodities` et `eu/hyjal`, et d'un historique simulé de la même taille, car aucun marché n'a encore deux semaines de données réelles.

| | |
| --- | --- |
| Site | 130 Mo de mémoire (mesuré sous Windows) |
| Fetcher | 110 Mo au plus fort d'un cycle, 20 Mo sans nouveau relevé |
| Postgres | Un quart de la mémoire du serveur, réglé par le script |
| Disque, par marché | Environ 1 Go pour 14 jours de détail horaire |
| Disque, résumés quotidiens | Environ 2 Mo par jour et par marché, jamais purgés |

2 Go de mémoire devraient être confortables pour les matières premières et un ou deux royaumes. Sur 1 Go, cela devrait passer avec le swap, sans garantie : ce n'est pas mesuré. Le temps des pages n'a pas non plus été mesuré sur un petit serveur.

Si le disque manque, réduis `WOW_HOURLY_RETENTION_DAYS` dans `/etc/wow-market/fetcher.env` : 7 divise le détail horaire par deux. Le fetcher ne s'exécute plus quand il reste moins de 1 Go libre, pour que Postgres et le site continuent de fonctionner, et `check.sh` le signale.

## Au quotidien

| Pour | Commande |
| --- | --- |
| Savoir si tout va bien | `sudo ./deploy/check.sh` |
| Lire les logs du fetcher | `journalctl -u wow-market-fetcher.service -f` |
| Lire les logs du site | `journalctl -u wow-market-site.service -f` |
| Lancer un cycle tout de suite | `sudo systemctl start --no-block wow-market-fetcher.service` |
| Mettre en pause le fetcher | `sudo systemctl stop wow-market-fetcher.timer` |
| Mettre à jour | `git pull && sudo ./deploy/install.sh` |
| Suivre d'autres marchés | Modifier `WOW_SCOPE` dans `/etc/wow-market/fetcher.env`, pris en compte au cycle suivant |
| Sauvegarder la base | `sudo -u postgres pg_dump -Fc wow_market > wow_market.dump` |

Aucune sauvegarde n'est automatique. L'historique ne peut pas se reconstruire, car Blizzard ne donne que l'état présent : un dump régulier, ou les instantanés de volume de Scaleway, sont le seul filet de sécurité.

## Ce que le script crée

| Quoi | Où |
| --- | --- |
| Programmes | `/opt/wow-market` |
| Identifiants et réglages, lisibles par root et `wowmarket` seulement | `/etc/wow-market/fetcher.env`, `/etc/wow-market/site.env` |
| Utilisateur système | `wowmarket` |
| Base et rôles Postgres | `wow_market`, `wowmarket` (propriétaire, pour le fetcher), `wowmarket_site` (lecture seule, pour le site) |
| Unités systemd | `wow-market-fetcher.service`, `wow-market-fetcher.timer`, `wow-market-site.service` |
| Avec un domaine | `/etc/caddy/Caddyfile`, l'ancien étant conservé en `Caddyfile.before-wow-market` |
