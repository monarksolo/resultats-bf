# RÉSULTATS-BF — Journal de bord

> À compléter au fil du projet (1 à 2 pages). Rappel du sujet : rotation obligatoire,
> c'est-à-dire que chaque membre doit avoir au moins un commit significatif en dehors
> de son domaine. L'historique Git en fait foi.

## Répartition des rôles

| Membre | Rôle | Périmètre principal | Contribution hors domaine (commit) |
|---|---|---|---|
| … | Architecte réseau et répartition | Plan d'adressage, Vagrantfile, HAProxy, sonde, E1 | |
| … | Ingénieur applicatif | `app/`, absence d'état, erreurs de base, E4 | |
| … | Ingénieur données | PostgreSQL, jeu de données, réplication, bascule | |
| … | Ingénieur essais et observabilité | Scénarios V1–V6, mesures, E2, résultats | |

## Jalons

| Jalon | Date prévue | Date atteinte | Remarque |
|---|---|---|---|
| J1 — `vagrant up` fonctionne de bout en bout | fin S1 | | |
| J2 — V1 et V2 passent | fin S2 | | |
| J3 — V4 passe | fin S3 | | |
| Rendu et soutenance | fin S4 | | |
| `destroy` + `up` sur le poste d'un autre membre | chaque semaine | | |

## Décisions prises, et pourquoi

| Date | Décision | Alternatives écartées | Raison |
|---|---|---|---|
| | HAProxy comme répartiteur | Nginx | Sondes actives, `retry-on`, API de drain, exportateur Prometheus |
| | Python + psycopg2 (paquets Ubuntu) | Node, pip | Aucun téléchargement hors apt, application en moins de 100 lignes |
| | Connexion multi-hôtes `target_session_attrs=read-write` | IP virtuelle pour la base, fichier de configuration à réécrire | Aucune reconfiguration des serveurs applicatifs lors de la bascule |
| | Promotion manuelle + `start.conf = manual` | Patroni, repmgr | Pas d'arbitre avec deux nœuds : risque de split brain |
| | Version de boîte `202510.26.0` | `202404.23.0` (squelette) | La version du squelette n'existe pas sur Vagrant Cloud |
| | Scripts en `run: always`, idempotents | Provisionnement unique | `NB_APP=4 vagrant up` doit reconfigurer le répartiteur déjà démarré |

## Difficultés rencontrées et solutions

| Date | Difficulté | Diagnostic | Solution |
|---|---|---|---|
| | | | |
| | | | |
