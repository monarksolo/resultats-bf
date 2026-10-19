#!/usr/bin/env bash
# Base de données PostgreSQL — bdd1 (rôle initial « bdd ») et bdd2 (« replique »).
#
# Le script est rejoué à chaque démarrage (run: always) et décide du rôle réel :
#   - si l'autre base est primaire  -> je suis (ou je redeviens) sa réplique en flux ;
#   - si je suis réplique et que la primaire est injoignable -> je reste réplique :
#     la promotion est une décision humaine, chronométrée (scripts/bascule-bdd.sh) ;
#   - sinon -> je suis primaire.
# PostgreSQL ne démarre pas seul au boot (start.conf = manual) : une ancienne
# primaire qui redémarre après une bascule ne peut donc pas accepter d'écritures
# avant que ce script l'ait reconstruite en réplique (pas de « split brain »).

source /vagrant/scripts/provision/commun.sh
ROLE_INITIAL=${1:-bdd}

installer_paquets "${PAQUETS_BASE[@]}" postgresql $(paquets_supervision)
maj_hosts
source /vagrant/scripts/provision/pg.sh
RESEAU=$($GENERER reseau)

# --- 1. Configuration (fichiers entièrement engendrés, jamais complétés par >>)
REDEMARRER=0; RECHARGER=0
deposer "$CONF/conf.d/resultats.conf" 644 postgres:postgres <<EOF && REDEMARRER=1
# Fichier engendré par scripts/provision/bdd.sh
listen_addresses = '*'
max_connections = 150
shared_buffers = '128MB'
password_encryption = 'scram-sha-256'
wal_level = replica
max_wal_senders = 10
wal_keep_size = '256MB'
hot_standby = on
EOF

deposer "$CONF/pg_hba.conf" 640 postgres:postgres <<EOF && RECHARGER=1
# Fichier engendré par scripts/provision/bdd.sh — trafic limité au réseau privé
# TYPE  BASE         UTILISATEUR    ADRESSE          MÉTHODE
local   all          postgres                        peer
local   all          all                             peer
host    all          all            127.0.0.1/32     scram-sha-256
host    resultats    resultats_app  $RESEAU     scram-sha-256
host    postgres     replicateur    $RESEAU     scram-sha-256
host    replication  replicateur    $RESEAU     scram-sha-256
EOF

if echo manual | deposer "$CONF/start.conf" 644 postgres:postgres; then
  systemctl daemon-reload
fi
echo "*:*:*:replicateur:$PG_MDP_REPLICATION" | deposer "$PGPASS" 600 postgres:postgres || true

demarrer() {
  if ! pg_actif; then
    systemctl start "$UNITE"
  elif [ "$REDEMARRER" = 1 ]; then
    systemctl restart "$UNITE"
  elif [ "$RECHARGER" = 1 ]; then
    systemctl reload "$UNITE"
  fi
  attendre_pg
}

reconstruire_replique() {
  log "construction de la réplique en flux depuis $PAIR_IP (pg_basebackup)"
  systemctl stop "$UNITE" || true
  rm -rf "$DATA"
  install -d -m 700 -o postgres -g postgres "$DATA"
  en_postgres "$PGBIN/pg_basebackup" -h "$PAIR_IP" -U replicateur -D "$DATA" -R -X stream -c fast -w
  systemctl start "$UNITE"
  attendre_pg
}

# Fixe le mot de passe d'un rôle seulement s'il ne permet pas déjà de se connecter
assurer_mdp() {
  local role=$1 mdp=$2 base=$3
  PGPASSWORD=$mdp psql -X -h 127.0.0.1 -U "$role" -d "$base" -Atqc 'SELECT 1' &>/dev/null && return 0
  log "mot de passe du rôle $role (re)défini"
  psql_local -v role="$role" -v mdp="$mdp" <<'SQL'
ALTER ROLE :"role" PASSWORD :'mdp';
SQL
}

initialiser_base() {
  psql_local <<'SQL'
SELECT 'CREATE ROLE replicateur WITH REPLICATION LOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicateur') \gexec
SELECT 'CREATE ROLE resultats_app WITH LOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'resultats_app') \gexec
SELECT 'CREATE DATABASE resultats OWNER resultats_app ENCODING ''UTF8'' TEMPLATE template0'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'resultats') \gexec
SQL
  assurer_mdp replicateur "$PG_MDP_REPLICATION" postgres
  assurer_mdp resultats_app "$PG_MDP_APP" resultats

  # Table et jeu de données : 50 000 lignes déterministes via generate_series
  psql_local -d resultats <<'SQL'
CREATE TABLE IF NOT EXISTS resultats (
    matricule text PRIMARY KEY,
    nom       text NOT NULL,
    serie     text NOT NULL,
    moyenne   numeric(4,2) NOT NULL CHECK (moyenne BETWEEN 0 AND 20),
    admis     boolean NOT NULL
);
GRANT SELECT, INSERT, UPDATE ON resultats TO resultats_app;

INSERT INTO resultats (matricule, nom, serie, moyenne, admis)
SELECT 'BF' || lpad(i::text, 6, '0'),
       (ARRAY['OUEDRAOGO','SAWADOGO','COMPAORE','KABORE','TRAORE',
              'ZONGO','OUATTARA','SANOU','KONATE','ILBOUDO'])[1 + i % 10] || ' ' ||
       (ARRAY['Aminata','Issouf','Mariam','Boukary','Salif',
              'Awa','Rasmané','Fatimata','Adama','Alizèta'])[1 + (i / 10) % 10],
       (ARRAY['A4','C','D','E','F3','G2'])[1 + i % 6],
       m, m >= 10
  FROM (SELECT i, round(((i * 7919) % 2001) / 100.0, 2) AS m
          FROM generate_series(1, 50000) AS i) AS s
 WHERE (SELECT count(*) FROM resultats) < 50000
ON CONFLICT (matricule) DO NOTHING;
SQL
  log "base resultats : $(psql_local -d resultats -c 'SELECT count(*) FROM resultats') lignes"
}

# --- 2. Rôle réel de cette base
if pair_est_primaire; then
  if est_replique && grep -q "host=$PAIR_IP " "$DATA/postgresql.auto.conf" 2>/dev/null; then
    log "réplique en flux de $PAIR_IP"
    demarrer
  else
    reconstruire_replique
  fi
elif est_replique; then
  log "réplique ; primaire $PAIR_IP injoignable : promotion manuelle via scripts/bascule-bdd.sh"
  demarrer
elif [ "$ROLE_INITIAL" = replique ] && [ ! -f "$MARQUEUR" ]; then
  # Toute première construction de la réplique : la primaire doit être prête
  log "attente de la primaire $PAIR_IP…"
  for ((i = 0; i < 120; i++)); do pair_est_primaire && break; sleep 1; done
  pair_est_primaire || { echo "Primaire $PAIR_IP injoignable : lancez d'abord bdd1." >&2; exit 1; }
  reconstruire_replique
else
  log "primaire (lecture et écriture)"
  demarrer
  initialiser_base
fi
[ -f "$MARQUEUR" ] || touch "$MARQUEUR"
