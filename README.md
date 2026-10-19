# RÉSULTATS-BF

Plateforme de consultation des résultats d'examens par numéro de matricule,
**résiliente** (la panne d'une machine n'interrompt pas le service) et
**scalable** (on ajoute des serveurs en changeant une seule valeur), entièrement
décrite en code avec Vagrant + VirtualBox.

> Master 1 Informatique — IBAM, Université Joseph Ki-Zerbo — Module DevOps et
> infrastructures reproductibles — Projet de groupe 2026-2027.

---

## 1. Démarrage rapide

```bash
git clone <url-du-depot> resultats-bf
cd resultats-bf
vagrant up
```

C'est tout. Au premier `vagrant up`, le fichier `.env` est créé automatiquement à
partir de `.env.exemple`, avec des mots de passe aléatoires. Comptez 15 à 30 minutes
la première fois (téléchargement de la boîte et des paquets).

Vérification :

```bash
curl http://localhost:8080/info
curl "http://localhost:8080/resultat?matricule=BF000042"
curl -i http://localhost:8080/sante
```

> **Numéro de groupe.** Nous sommes le **groupe 10**, valeur par défaut de `.env.exemple`.
> La plateforme utilise donc le sous-réseau **`192.168.57.0/24`** (voir la section 3 pour
> la règle de calcul). Un autre groupe changerait `GROUPE` dans `.env` avant le premier
> `vagrant up`.

### Prérequis (poste hôte)

| Outil | Version | Remarque |
|---|---|---|
| VirtualBox | 7.0 ou plus récent (6.1.28 au minimum) | Sous Windows, Hyper-V et la plateforme de machine virtuelle doivent être désactivés pour de bonnes performances |
| Vagrant | 2.4 ou plus récent | Aucun greffon nécessaire |
| Git | toute version récente | Sous Windows, **Git Bash** sert aussi à lancer les scénarios (`scenarios/*.sh`) |
| Mémoire | 8 Go | Socle : 3 Go pour les VM ; avec E1 + E2 : 4,3 Go |
| Disque | ~10 Go libres | |

Aucun compte cloud, aucune ressource payante, aucune image construite à la main :
tout part de la boîte publique `bento/ubuntu-24.04` (version épinglée) et des scripts du dépôt.

---

## 2. Architecture

```
                         Réseau privé du groupe 10 : 192.168.57.0/24 (host-only)
                    ┌──────────────────────────────────────────────────────────────┐
  Poste hôte        │   IP virtuelle .5 (VRRP)                                     │
  navigateur ──8080─┼─► lb1 .11 actif ─┐            app1 .21:3000 ─┐               │
  ab / curl         │   HAProxy +      ├─ HTTP ─►   app2 .22:3000 ─┼─ SQL 5432 ─► bdd1 .31 primaire
            ──VIP───┼─► lb2 .12 passif ┘  /sante    app3…appN     ─┘               │     │ réplication
                    │   (E1)                        (NB_APP)                       │     ▼ en flux
                    │                                                    bdd2 .32 réplique (promouvable)
                    │   obs .41 — Prometheus + Grafana (E2) ··· collecte toutes les machines
                    └──────────────────────────────────────────────────────────────┘
```

| Machine | Rôle | Adresse | RAM | Statut |
|---|---|---|---|---|
| bdd1 | PostgreSQL 16 primaire — lecture et écriture | .31 | 768 Mo | Socle |
| bdd2 | Réplique en flux, promouvable | .32 | 768 Mo | Socle |
| app1 … appN | Serveurs applicatifs sans état (N ≥ 2, Python) | .21 … .2N | 512 Mo | Socle |
| lb1 | HAProxy actif (+ keepalived si E1) | .11 | 512 Mo | Socle |
| lb2 | HAProxy passif, IP virtuelle VRRP | .12 | 512 Mo | Extension E1 |
| obs | Prometheus, Grafana (+ node_exporter partout) | .41 | 768 Mo | Extension E2 |

### Source unique de vérité

Le `Vagrantfile` construit la table `NOEUDS` à partir de `GROUPE`, `NB_APP` et
`EXTENSIONS`, puis l'écrit dans `config/noeuds.yml`. Les scripts de provisionnement
lisent ce fichier (via `scripts/provision/generer.py`) pour **engendrer** :

- la liste des serveurs de HAProxy (`/etc/haproxy/haproxy.cfg`) ;
- la configuration keepalived (pairs VRRP, IP virtuelle) ;
- les cibles de Prometheus ;
- la liste des bases que l'application interroge ;
- le bloc `/etc/hosts` de chaque machine.

**Aucune adresse de serveur applicatif n'est écrite à la main dans une configuration.**

### L'application (`app/resultats.py`, 99 lignes, Python + psycopg2)

| Point d'entrée | Comportement |
|---|---|
| `GET /resultat?matricule=BF000042` | Résultat du candidat (JSON) lu dans la base ; 404 si inconnu |
| `GET /sante` | 200 si la base primaire répond à une requête SQL, avec l'adresse de cette base ; 503 sinon. Jamais 200 « par principe » |
| `GET /info` | Nom d'hôte et version du serveur qui a répondu |

Le service ne conserve **aucun état** : ni session, ni fichier local, ni compteur
(le service systemd est même lancé avec `ProtectSystem=strict`). Il se connecte à
`bdd1,bdd2` avec `target_session_attrs=read-write` : libpq choisit seule la base qui
accepte les écritures. Après une bascule, il n'y a donc rien à reconfigurer. Il
démarre même si la base est absente et réessaie à chaque requête.

La table `resultats (matricule, nom, serie, moyenne, admis)` contient 50 000 lignes
engendrées par `generate_series`. Les données sont déterministes, donc identiques à
chaque reconstruction. Les matricules vont de `BF000001` à `BF050000`.

---

## 3. Paramètres (`.env`)

Ordre de priorité : variable d'environnement, puis fichier `.env`, puis valeur par défaut.

| Variable | Défaut | Rôle |
|---|---|---|
| `GROUPE` | 10 | Numéro de groupe → sous-réseau `192.168.(56 + (G−1) mod 8).0/24` |
| `NB_APP` | 2 | Nombre de serveurs applicatifs (2 à 9) |
| `EXTENSIONS` | `E1,E2` | Extensions déployées ; vide = socle seul (5 VM, 3 Go) |
| `BOITE_VERSION` | `202510.26.0` | Version épinglée de `bento/ubuntu-24.04` |
| `PG_MDP_APP`, `PG_MDP_REPLICATION`, `VRRP_MDP`, `GRAFANA_MDP_ADMIN` | aléatoires | Secrets (R7) |

> **Note sur la version de la boîte.** Le squelette du sujet cite `202404.23.0`, mais
> cette version n'existe pas sur Vagrant Cloud. Nous avons épinglé `202510.26.0`, qui
> est disponible pour VirtualBox amd64. `202404.26.0` est une alternative valable.

Pour travailler sur le socle seul pendant le développement, mettez `EXTENSIONS=` dans `.env`.
Ne le faites pas en ligne de commande (`EXTENSIONS= vagrant up`) : sous Windows, une
variable d'environnement vide est supprimée, et c'est alors la valeur de `.env` qui s'applique.

> **Sous-réseau du groupe 10.** Le sujet attribue `192.168.(55+G).0/24` à des groupes
> numérotés de 1 à 8, pour rester dans `192.168.56.0/21`, la seule plage qu'un VirtualBox
> récent autorise par défaut. Appliquée au groupe 10, la formule donnerait
> `192.168.65.0/24`. Ce réseau est accepté sous Windows, mais refusé sous Linux et macOS
> sans modifier `/etc/vbox/networks.conf`, ce que le sujet interdit. Nous prolongeons
> donc la formule par `56 + (G−1) mod 8` :
>
> - pour les groupes 1 à 8, elle donne exactement `55+G` ;
> - pour le groupe 10, elle donne `192.168.57.0/24`, dans la plage autorisée sur tous
>   les systèmes.
>
> Ce réseau est le même que celui du groupe 2, sans conséquence : un réseau hôte-seul
> est propre à chaque poste.

---

## 4. Accès

| Service | Adresse (groupe 10) |
|---|---|
| **Interface graphique** | http://localhost:8080/ ou, avec E1, http://192.168.57.5/ |
| Service public, via lb1 | http://localhost:8080 (seul port redirigé vers l'hôte, R8) |
| Service public, via l'IP virtuelle (E1) | http://192.168.57.5 |
| Statistiques HAProxy | http://192.168.57.11:8404/stats |
| Grafana (E2), lecture anonyme | http://192.168.57.41:3000. Compte `admin`, mot de passe `GRAFANA_MDP_ADMIN` dans `.env` |
| Prometheus (E2) | http://192.168.57.41:9090/targets |

### Interface graphique

La page `app/interface.html` est un fichier statique, sans dépendance externe, que
**HAProxy sert lui-même** (`http-request return`). Les serveurs applicatifs ne sont donc
pas sollicités pour l'afficher, et l'application reste sous les 100 lignes. La page
n'utilise que les points d'entrée publics :

| Zone | Ce qu'elle montre | Source |
|---|---|---|
| Consulter un résultat | Fiche du candidat, moyenne, mention, « servi par app2 via lb1 en 12 ms » | `/resultat`, en-têtes `X-Serveur` et `X-Repartiteur` |
| Infrastructure en direct | Répartiteur actif, état de chaque serveur vu par HAProxy (en service, hors service, drain), base primaire | `/etat-lb;csv` (statistiques HAProxy en lecture seule), `/sante` (IP de la base qui a répondu), `/noeuds.json` (carte engendrée depuis `noeuds.yml`) |
| Trafic simulé | 5 à 20 req/s vers `/info`, histogramme réussites/erreurs par seconde, répartition par serveur et version déployée | `/info` |
| Journal | Changements d'état horodatés : serveur hors service, bascule VRRP, bascule de la base… | calculé dans la page |

Pour une démonstration parlante, ouvrez la page **via l'IP virtuelle**
(http://192.168.57.5/), démarrez le trafic simulé, puis lancez une panne (`vagrant halt
app1`, `vagrant halt lb1` ou `vagrant halt bdd1`). La page passe par la bonne adresse
même quand lb1 tombe, alors que `localhost:8080` dépend de lb1. Fermez la page pendant
les mesures de V3 : ses sondes ajoutent de la charge.

---

## 5. Exigences obligatoires : comment elles sont satisfaites

| N° | Exigence | Mise en œuvre | Vérification |
|---|---|---|---|
| R1 | Reconstruction intégrale | `.env` engendré automatiquement ; scripts autonomes et ordonnés (bdd1 → bdd2 → apps → lb → obs) ; la réplique attend la primaire | `scenarios/v5-reconstruction.sh --oui` |
| R2 | Idempotence | Fichiers **entièrement engendrés** puis comparés (`deposer`), jamais complétés par `>>` ; un service n'est rechargé que si sa configuration a changé ; paquets installés seulement s'ils manquent | `scenarios/r2-idempotence.sh` |
| R3 | `NB_APP` paramétrable | Table `NOEUDS` → `config/noeuds.yml` → HAProxy, Prometheus. Scripts en `run: "always"` : `NB_APP=4 vagrant up` reconfigure aussi le répartiteur déjà en marche | `NB_APP=4 vagrant up` puis `scenarios/v1-repartition.sh` |
| R4 | Sonde de santé | `option httpchk GET /sante`, `inter 1s fastinter 500ms fall 2`, `timeout check 1.5s` : un serveur est écarté en 1 à 4 s. En plus, `retry-on` + `redispatch` rejouent ailleurs une requête interrompue | `scenarios/v2-panne-app.sh` |
| R5 | Réplication en flux | `pg_basebackup -R` (réplication physique en flux), `wal_keep_size` | `scenarios/r5-replication.sh` |
| R6 | Procédure de bascule | `scripts/bascule-bdd.sh` : garde-fou anti « split brain », `pg_promote()`, attente du retour de `/sante`, chronométrage | `scenarios/v4-panne-bdd.sh` |
| R7 | Aucun secret en clair | `.env` ignoré par Git, `.env.exemple` versionné ; secrets transmis aux scripts par variables d'environnement ; fichiers de secrets en mode 600/640 dans les VM | `git log -p \| grep -i mdp` |
| R8 | Trafic interne sur le réseau privé | Toutes les communications utilisent les adresses `192.168.57.x`. Seul le port 80 des répartiteurs est redirigé (lb1 → 8080, lb2 → 8081, liés à 127.0.0.1) | Lecture du `Vagrantfile` |

Remarque R8 : Vagrant redirige en plus, pour chaque VM, un port SSH (2222…) vers
l'hôte. Ce port sert à l'administration par `vagrant ssh` et ne transporte aucun
trafic applicatif.

### Extensions réalisées

| Code | Extension | Démonstration |
|---|---|---|
| **E1** | lb2 + keepalived, IP virtuelle `.5` en VRRP (unicast, `advert_int 1`, suivi de l'état de HAProxy) | `scenarios/v6-panne-lb.sh` |
| **E2** | Prometheus + node_exporter + exportateur HAProxy + Grafana (tableau de bord provisionné) | Ouvrir Grafana pendant V2/V3 |
| **E4** (bonus) | Déploiement serveur par serveur : drain HAProxy → mise à jour → remise en service | `scenarios/e4-deploiement.sh` |

---

## 6. Scénarios de validation

Tous les scénarios s'exécutent **sur l'hôte**, depuis la racine du dépôt (sous Windows :
Git Bash). Chacun écrit sa sortie brute dans `mesures/` pour le dossier.

| N° | Commande | Mesure relevée |
|---|---|---|
| V1 | `scenarios/v1-repartition.sh` | Écart entre le serveur le plus et le moins sollicité |
| V2 | `scenarios/v2-panne-app.sh` | Requêtes perdues, durée de la période dégradée |
| V3 | `scenarios/v3-montee-charge.sh --comparer` | Requêtes/s avec N=2 puis N=4 (`ab -n 2000 -c 50`, 3 répétitions) |
| V4 | `scenarios/v4-panne-bdd.sh` | 503 propre, puis durée totale de la bascule |
| V5 | `scenarios/v5-reconstruction.sh --oui` | Durée totale `destroy` + `up` |
| V6 | `scenarios/v6-panne-lb.sh` | Requêtes perdues et temps de reprise après la bascule VRRP |
| R2 | `scenarios/r2-idempotence.sh` | Fichiers modifiés au second rejeu (attendu : 0) |
| R5 | `scenarios/r5-replication.sh` | Écriture sur la primaire, lecture sur la réplique |
| E4 | `scenarios/e4-deploiement.sh` | Requêtes en erreur pendant la mise à jour (attendu : 0) |

**Sous Windows**, chaque commande `vagrant` (y compris `vagrant halt` et `vagrant ssh`) met
de 10 s à 2 min pour s'exécuter quand l'hôte est chargé. Lors de nos essais, `vagrant halt
app1` pendant V2 a pris environ 3 min, dont seulement 20 s d'arrêt réel dans la VM. Ce délai
ne fausse pas les mesures, qui portent sur les requêtes, mais il faut le prévoir dans les
20 minutes de démonstration.

L'injecteur de charge `ab` tourne dans une VM : `obs` si E2 est active, sinon `lb1`.
Toutes les VM partagent le processeur de l'hôte, il ne faut donc pas s'attendre à ce
que doubler N double le débit (voir le dossier d'architecture).

---

## 7. Procédures d'exploitation

### Ajouter ou retirer des serveurs applicatifs

```bash
scripts/echelle.sh 4          # crée app3, app4 ; HAProxy, PostgreSQL et Prometheus suivent
scripts/echelle.sh 2          # retire app3, app4 du répartiteur, PUIS les détruit
```

Équivalent manuel pour l'ajout : `NB_APP=4 vagrant up`, ou `NB_APP=4` dans `.env` puis `vagrant up`.

### Bascule de la base (panne de bdd1)

```bash
vagrant halt bdd1             # (ou panne réelle)
scripts/bascule-bdd.sh bdd2   # promotion chronométrée ; le service revient seul
vagrant up bdd1               # bdd1 se reconstruit en réplique de bdd2
```

PostgreSQL ne démarre pas automatiquement au boot (`start.conf = manual`). C'est le
provisionnement (`run: always`) qui décide du rôle de chaque base au démarrage :

- une ancienne primaire qui revient après une bascule est reconstruite en réplique ;
- elle ne peut donc jamais accepter d'écritures en concurrence avec la nouvelle primaire.

Pour revenir ensuite à bdd1 primaire : `vagrant halt bdd2`, puis
`scripts/bascule-bdd.sh bdd1`, puis `vagrant up bdd2`.

### Mettre à jour l'application sans coupure (E4)

Modifier `app/resultats.py` (par exemple `VERSION = "1.1.0"`), puis :

```bash
scripts/deployer.sh
```

### Commandes utiles

```bash
vagrant status
vagrant ssh lb1 -c "echo 'show stat' | sudo socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18"
vagrant ssh bdd1 -c "sudo -u postgres psql -c 'select client_addr, state from pg_stat_replication'"
vagrant ssh app1 -c "journalctl -u resultats -n 20"
```

---

## 8. Arborescence

```
Vagrantfile                 source unique de vérité (table NOEUDS) + définition des VM
.env.exemple                modèle de configuration et de secrets (versionné)
.gitattributes              fins de ligne LF pour tous les scripts
app/
  resultats.py              service HTTP sans état (99 lignes)
  interface.html            interface graphique, servie par HAProxy
  resultats.service         unité systemd
config/
  noeuds.yml                ENGENDRÉ par le Vagrantfile (non versionné)
  grafana/resultats-bf.json tableau de bord Grafana (E2)
scripts/
  provision/                exécutés DANS les VM par Vagrant
    commun.sh               fonctions idempotentes (paquets groupés, cache .deb, deposer…)
    generer.py              configurations engendrées depuis noeuds.yml
    bdd.sh, pg.sh           PostgreSQL primaire/réplique, rôle décidé au démarrage
    promouvoir.sh           promotion de la réplique locale (appelé par bascule-bdd.sh)
    haproxy-serveur.sh      drain / remise en service d'un serveur dans HAProxy (appelé par deployer.sh)
    app.sh, lb.sh, obs.sh   serveurs applicatifs, répartiteurs, supervision
  bascule-bdd.sh            R6 — procédure de bascule chronométrée (hôte)
  echelle.sh                R3 — ajout et retrait de serveurs (hôte)
  deployer.sh               E4 — déploiement serveur par serveur (hôte)
scenarios/                  V1 à V6, R2, R5, E4 (hôte) ; résultats bruts dans mesures/
docs/
  dossier-architecture.md   L2 — dossier d'architecture
  journal-de-bord.md        L3 — journal de bord
```

---

## 9. Dépannage

| Symptôme | Cause probable et solution |
|---|---|
| `The specified host network collides…` ou adresse refusée | Le réseau calculé depuis `GROUPE` reste toujours dans `192.168.56.0/21`. Vérifiez qu'aucune autre carte réseau du poste n'utilise déjà `192.168.57.0/24`. Ne modifiez pas `/etc/vbox/networks.conf` |
| `VT-x is not available` / VM très lente sous Windows | Désactiver Hyper-V : `bcdedit /set hypervisorlaunchtype off`, puis redémarrer |
| Port 8080 déjà utilisé | Libérer le port, ou changer `port_hote` de lb1 dans le `Vagrantfile` |
| `bash\r: No such file or directory` | Fins de ligne CRLF : vérifier `.gitattributes`, puis `git rm --cached -r . && git reset --hard` |
| `/sante` renvoie 503 partout | Aucune base primaire : `scripts/bascule-bdd.sh`, ou `vagrant up bdd1` |
| Une VM redémarrée « à la main » (`sudo reboot`) n'a pas PostgreSQL | Normal (`start.conf = manual`) : utilisez `vagrant reload bdd1` ou `vagrant up bdd1` |
| Après `NB_APP=4 vagrant up`, un `vagrant up` simple revient à 2 serveurs | Mettre `NB_APP=4` dans `.env`, ou utiliser `scripts/echelle.sh 4` |
