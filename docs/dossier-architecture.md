# RÉSULTATS-BF — Dossier d'architecture

**Groupe n° 10 — sous-réseau 192.168.57.0/24**
Membres : … (architecte réseau et répartition), … (ingénieur applicatif),
… (ingénieur données), … (ingénieur essais et observabilité)

> Les sections 1 à 5 et 7 décrivent ce qui est construit par le dépôt.
> Les tableaux de la section 6 doivent être remplis **avec vos propres mesures**,
> en recopiant les sorties brutes de `mesures/`. Aucune valeur n'est pré-remplie :
> une mesure inventée est pénalisée, et un résultat décevant mais expliqué vaut
> mieux qu'une belle courbe fausse.

---

## 1. Contexte

Chaque année, le site de publication des résultats tombe dans les minutes qui
suivent l'annonce. En cause, une infrastructure qui n'est conçue ni pour absorber
un pic de consultations, ni pour survivre à la panne d'une machine. Deux exigences
non fonctionnelles priment :

- **Résilience** : la panne d'une machine ne doit pas interrompre le service.
- **Scalabilité** : on absorbe plus de trafic en ajoutant des machines, sans réécrire la configuration.

L'application est volontairement minuscule. Ce qui est évalué, c'est l'infrastructure
autour d'elle et la preuve, mesurée, qu'elle tient.

## 2. Architecture

*(Insérer ici le schéma : figure 1 du sujet, ou celui du README.)*

| Couche | Machines | Technologie | Redondance |
|---|---|---|---|
| Entrée | lb1 (actif), lb2 (passif) | HAProxy 2.8, keepalived (VRRP) | IP virtuelle `.5` reprise par lb2 en moins de 5 s |
| Application | app1 … appN | Python 3.12, `http.server`, psycopg2, systemd | N ≥ 2 serveurs sans état, sonde `/sante` |
| Données | bdd1 (primaire), bdd2 (réplique) | PostgreSQL 16, réplication physique en flux | Promotion de bdd2 par procédure chronométrée |
| Supervision | obs | Prometheus, node_exporter, exportateur HAProxy, Grafana | (hors chemin critique) |

### 2.1. Plan d'adressage

| Plage | Usage |
|---|---|
| `.5` | IP virtuelle VRRP (service public) |
| `.11`–`.12` | Répartiteurs |
| `.21`–`.29` | Serveurs applicatifs (`20 + i`, d'où N ≤ 9) |
| `.31`–`.32` | Bases de données |
| `.41` | Supervision |

Depuis sa version 6.1.28, VirtualBox n'autorise par défaut que la plage
`192.168.56.0/21` (`192.168.56.x` à `192.168.63.x`). Le sujet prévoit
`192.168.(55+G).0/24` pour des groupes numérotés de 1 à 8. Pour notre groupe 10, cette
formule donnerait `192.168.65.0/24` :

- **sous Windows**, ce réseau est accepté ;
- **sous Linux et macOS**, il est refusé tant qu'on ne modifie pas
  `/etc/vbox/networks.conf`, ce que le sujet interdit. La démonstration sur un poste
  vierge échouerait donc.

Nous prolongeons la formule par **`56 + (G−1) mod 8`** :

- pour les groupes 1 à 8, elle donne exactement `55+G` ;
- pour le groupe 10, elle donne **`192.168.57.0/24`**, accepté partout sans configuration.

Ce réseau est le même que celui du groupe 2. Cela n'a pas de conséquence, car un réseau
hôte-seul n'existe que sur le poste qui l'héberge. La règle est appliquée dans le
`Vagrantfile`, et toutes les adresses en découlent.

### 2.2. Flux

| Source | Destination | Port | Contenu |
|---|---|---|---|
| Hôte | lb1 (redirection 127.0.0.1:8080), ou IP virtuelle | 80 | HTTP public |
| lb1, lb2 | app1…appN | 3000 | HTTP + sonde `/sante` toutes les secondes |
| app* | bdd1, bdd2 | 5432 | SQL (rôle `resultats_app`) |
| bdd2 | bdd1 (ou l'inverse après bascule) | 5432 | Réplication (rôle `replicateur`) |
| lb1 ↔ lb2 | — | VRRP (protocole 112, unicast) | Annonces keepalived |
| obs | toutes les VM | 9100, 8404 | Collecte Prometheus |

## 3. Justification des choix

### 3.1. Source unique de vérité (R3)
La table `NOEUDS` du `Vagrantfile` est sérialisée dans `config/noeuds.yml`. Toutes
les configurations qui dépendent de la topologie en sont **engendrées** par
`scripts/provision/generer.py` : backend HAProxy, pairs keepalived, cibles
Prometheus, liste des hôtes PostgreSQL de l'application, `/etc/hosts`. Passer de 2 à 4
serveurs se fait en changeant une seule valeur (`NB_APP`). Comme les scripts sont en
`run: "always"`, `NB_APP=4 vagrant up` reprovisionne aussi lb1, déjà en marche. HAProxy
est rechargé (`reload`) sans perdre de connexion.

### 3.2. HAProxy plutôt que Nginx
- Sonde de santé HTTP active, réglable à la seconde (`inter 1s fastinter 500ms fall 2`).
  Nginx libre ne propose que des sondes passives.
- `retry-on conn-failure empty-response response-timeout` et `option redispatch` : une
  requête interrompue par l'arrêt d'un serveur est rejouée sur un autre. Les requêtes
  sont des GET idempotents, ce rejeu est donc sans risque.
- API d'exécution (socket admin) pour le drain du déploiement sans coupure (E4).
- Exportateur Prometheus intégré (E2).

### 3.3. Une sonde `/sante` qui dit vrai (R4)
`/sante` exécute `SELECT 1` sur une connexion **en lecture-écriture**. Si aucune base
primaire n'est joignable, elle renvoie 503. HAProxy retire alors le serveur, et si
tous les serveurs sont retirés, HAProxy renvoie sa propre page 503 au format JSON.
L'utilisateur ne voit jamais de page blanche ni d'erreur de connexion brute.

Délai d'éviction d'un serveur en panne :

- serveur arrêté (connexion refusée) : environ 1 à 2 s ;
- serveur figé : au pire 1,5 s + 0,5 s + 1,5 s ≈ 3,5 s.

Les deux restent sous les 5 s exigées.

### 3.3 bis. Interface graphique servie par le répartiteur
L'interface (`app/interface.html`) est un fichier statique que HAProxy sert depuis sa
mémoire (`http-request return`), comme le ferait un cache de périphérie :

- elle ne coûte rien aux serveurs applicatifs ;
- elle ne fait pas dépasser à l'application la limite de 100 lignes.

Elle ne lit que des points d'entrée publics :

- `/resultat` ;
- `/sante`, qui renvoie l'adresse de la base ayant répondu et rend ainsi la bascule visible ;
- `/info` ;
- les statistiques HAProxy en lecture seule (`/etat-lb;csv`, sans le niveau admin) ;
- `/noeuds.json`, engendré depuis la même source de vérité que le reste.

L'en-tête `X-Repartiteur` indique quel répartiteur a traité la requête, ce qui rend la
bascule VRRP visible. Pendant la démonstration, la page montre en direct ce que les
scénarios mesurent.

### 3.4. Application sans état
Aucune session, aucun fichier, aucun compteur. Le service systemd tourne en
`ProtectSystem=strict` : il ne *peut* rien écrire sur le disque. Le seul objet en
mémoire est un cache de connexions PostgreSQL, qui n'est pas un état applicatif : le
perdre ne coûte qu'une reconnexion. Ajouter ou retirer un serveur est donc indolore.

### 3.5. Bascule de la base sans reconfiguration des serveurs applicatifs
L'application se connecte à `host=bdd1,bdd2 target_session_attrs=read-write`. libpq
essaie les hôtes dans l'ordre et ne garde que celui qui accepte les écritures. Après
la promotion de bdd2, les serveurs applicatifs le trouvent seuls. Le chemin de
bascule ne comporte ni fichier à modifier ni service à redémarrer.

### 3.6. Promotion manuelle plutôt qu'automatique
Une promotion automatique (Patroni, repmgr) exige un arbitre (quorum, etcd). Avec deux
bases seulement, elle expose au « split brain » : par exemple, une coupure réseau
entre bdd1 et bdd2 ferait deux primaires. Nous avons choisi une **procédure humaine,
écrite et chronométrée** (`scripts/bascule-bdd.sh`), assortie de deux garde-fous :

1. la promotion est refusée si l'ancienne primaire répond encore ;
2. PostgreSQL ne démarre pas seul au boot (`start.conf = manual`). Au démarrage, le
   provisionnement interroge l'autre base. Si elle est déjà primaire, la machine qui
   revient est reconstruite en réplique (`pg_basebackup`). Une ancienne primaire ne
   peut donc jamais recevoir d'écritures en parallèle de la nouvelle.

### 3.7. Répartiteur redondant en VRRP (E1)
keepalived en unicast, plutôt qu'en multicast, pour ne pas dépendre du comportement
du réseau host-only. `advert_int 1`. Le script de suivi bascule l'IP virtuelle si
HAProxy s'arrête sur lb1. Sur arrêt propre de lb1, keepalived émet une annonce de
priorité 0 et lb2 reprend presque immédiatement. Sur panne brutale, la reprise prend
environ 3 × 1 s + décalage, soit moins de 4 s.

### 3.8. Reproductibilité et idempotence (R1, R2)
- Boîte `bento/ubuntu-24.04` épinglée (`202510.26.0`). La version `202404.23.0` du
  squelette n'existe pas sur Vagrant Cloud.
- `.env` engendré automatiquement avec des secrets aléatoires : aucun geste manuel après le clonage.
- Chaque fichier de configuration est **entièrement engendré** puis comparé à
  l'existant (fonction `deposer`). Il n'est réécrit, et son service rechargé, que s'il
  a changé. Aucun `>>`.
- Un seul `apt-get install` groupé par machine, lancé seulement s'il manque un paquet.
  Les `.deb` téléchargés sont mis en commun entre VM via `/vagrant/.cache/apt` :
  sur une connexion lente, on ne télécharge pas quatre fois la même chose.
- Ordre de démarrage : bdd1 → bdd2 (qui attend la primaire) → apps → lb → obs. En
  outre, l'application supporte une base absente et réessaie.
- Fins de ligne LF imposées par `.gitattributes`.

### 3.9. Secrets (R7)
Quatre secrets (`PG_MDP_APP`, `PG_MDP_REPLICATION`, `VRRP_MDP`, `GRAFANA_MDP_ADMIN`)
vivent dans `.env`, ignoré par Git. Ils sont transmis aux scripts par variables
d'environnement (`env:` du provisionneur shell). Dans les VM, ils sont écrits dans
des fichiers en mode 600 ou 640 (`.pgpass`, `app.env`, `keepalived.conf`, unité
Grafana).

## 4. Points de défaillance unique

| Composant | Avant | Après | Reste-t-il un SPOF ? |
|---|---|---|---|
| Serveur applicatif | 1 serveur | N ≥ 2 + sonde de santé | Non |
| Répartiteur | lb1 seul | lb1 + lb2 + VRRP (E1) | Non, avec E1 ; oui, avec le socle seul |
| Base de données | bdd1 seule | bdd1 + réplique bdd2 | Bascule **manuelle** : indisponibilité des écritures et de `/sante` le temps de la procédure (V4) |
| Hôte physique | — | — | **Oui** : toutes les VM sont sur un seul poste (limite du cadre du projet) |
| Supervision | — | obs | Hors chemin critique |

## 5. Procédures d'exploitation

### 5.1. Bascule de la base (R6)
1. Constater la panne (`/sante` en 503, panneau Grafana, `vagrant status`).
2. `scripts/bascule-bdd.sh bdd2`. Le script refuse si bdd1 répond encore, promeut
   bdd2, attend que `/sante` revienne à 200, puis affiche les durées.
3. Réintégration : `vagrant up bdd1`. bdd1 est reconstruite en réplique de bdd2.
4. Retour optionnel à la situation initiale : `vagrant halt bdd2`, puis
   `scripts/bascule-bdd.sh bdd1`, puis `vagrant up bdd2`.

### 5.2. Ajout ou retrait d'un serveur applicatif
- Ajout : `scripts/echelle.sh 4`, ou `NB_APP=4 vagrant up`.
- Retrait : `scripts/echelle.sh 2`. La configuration est d'abord régénérée sans les
  serveurs en trop, qui ne reçoivent donc plus de trafic, puis ces serveurs sont détruits.

### 5.3. Mise à jour de l'application (E4)
`scripts/deployer.sh`, serveur par serveur :

1. `drain` sur tous les répartiteurs ;
2. `vagrant provision appX` (le service n'est redémarré que si le code a changé) ;
3. `ready` ;
4. attente de l'état UP.

## 6. Résultats des scénarios

Conditions de mesure : poste …, processeur …, mémoire …, système …, VirtualBox …,
Vagrant …, extensions actives …. L'injecteur `ab` tourne dans la VM … .

### V1 — Répartition (`scenarios/v1-repartition.sh`)
| Serveur | Réponses sur 20 |
|---|---|
| app1 | |
| app2 | |
| **Écart (max − min) / moyenne** | |

Commentaire : …

### V2 — Panne d'un serveur applicatif sous charge (`scenarios/v2-panne-app.sh`)
| Mesure | Valeur |
|---|---|
| Requêtes envoyées | |
| Requêtes en erreur | |
| Période dégradée | |

Commentaire : …

### V3 — Montée en charge (`scenarios/v3-montee-charge.sh --comparer`)
| Configuration | Essai 1 (req/s) | Essai 2 | Essai 3 | Médiane | Requêtes en échec |
|---|---|---|---|---|---|
| N = 2 | | | | | |
| N = 4 | | | | | |

Commentaire, à rédiger honnêtement : les VM partagent les cœurs de l'hôte. Ajouter
deux VM ajoute de la concurrence pour le CPU, sans ajouter de CPU. Le débit peut
stagner, voire baisser. Le goulot d'étranglement probable est … (le CPU de l'hôte, ou
le serveur Python mono-processus, à vérifier sur le panneau CPU de Grafana).

### V4 — Panne de la base primaire (`scenarios/v4-panne-bdd.sh`)
| Mesure | Valeur |
|---|---|
| Réponse de `/sante` pendant la panne | (copier le JSON 503) |
| Durée de la promotion | |
| Retour de `/sante` à 200 après la promotion | |
| **Durée totale de la bascule** | |

Commentaire : …

### V5 — Reconstruction (`scenarios/v5-reconstruction.sh --oui`)
| Mesure | Valeur |
|---|---|
| Destruction | |
| Construction | |
| **Durée totale** | |
| Intervention manuelle | aucune |

### V6 — Panne du répartiteur actif (`scenarios/v6-panne-lb.sh`)
| Mesure | Valeur |
|---|---|
| Requêtes en erreur | |
| Temps de reprise (période dégradée) | |
| Porteur de l'IP virtuelle après la panne | |

### R2 et R5
| Vérification | Résultat |
|---|---|
| Fichiers réécrits au second `vagrant provision` | |
| Différences d'empreintes dans `/etc` et `/opt` | |
| Ligne écrite sur la primaire, lue sur la réplique | |

## 7. Limites connues et ce que nous ferions autrement

- **Une seule machine physique** : la résilience démontrée est logicielle. En production,
  il faudrait des hôtes et des zones distincts.
- **Bascule de la base manuelle** : avec un troisième nœud (témoin ou etcd), Patroni
  automatiserait la bascule sans risque de split brain.
- **Ordre des hôtes libpq** : après la bascule, chaque *nouvelle* connexion essaie
  d'abord bdd1, éteinte, et attend `connect_timeout` (2 s). Le cache de connexions
  limite ce coût à la première requête de chaque connexion. Pour l'éliminer : un
  routeur de connexions (PgBouncer, HAProxy en TCP avec vérification du rôle), ou
  l'option `load_balance_hosts`.
- **Lectures sur la réplique** : la réplique pourrait servir `/resultat` en lecture
  pendant la panne de la primaire. Nous avons gardé une sonde stricte, conforme au
  sujet.
- **Serveur HTTP Python** : `ThreadingHTTPServer` suffit pour la démonstration. En
  production : gunicorn ou uvicorn, avec plusieurs processus.
- **Cache (E3) non réalisé** : un Redis devant la base, à invalider lors de la
  publication de nouveaux résultats.
- **Réplication asynchrone** : une écriture confirmée sur bdd1 juste avant sa panne
  peut manquer sur bdd2. `synchronous_commit` avec une réplique synchrone éviterait
  cette perte, au prix de la disponibilité des écritures si la réplique tombe.
