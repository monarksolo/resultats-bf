#!/usr/bin/env bash
# Variables et fonctions PostgreSQL partagées par bdd.sh et promouvoir.sh.
# À sourcer après commun.sh.

PGVER=$(ls /usr/lib/postgresql 2>/dev/null | sort -V | tail -1)
PGBIN=/usr/lib/postgresql/$PGVER/bin
CONF=/etc/postgresql/$PGVER/main
DATA=/var/lib/postgresql/$PGVER/main
UNITE=postgresql@$PGVER-main
PGPASS=/var/lib/postgresql/.pgpass
MARQUEUR=/var/lib/postgresql/.resultats-initialise

MOI=$(hostname)
# L'autre base (primaire ou réplique) d'après la source unique de vérité.
# Pas de « exit » dans awk : il fermerait le tube avant la fin de l'écriture
# (BrokenPipe, fatal avec pipefail).
PAIR_IP=$( { noeuds_role bdd; noeuds_role replique; } | awk -v moi="$MOI" '$1 != moi && !vu {print $2; vu = 1}')

en_postgres() { sudo -u postgres env PGPASSFILE="$PGPASS" PGCLIENTENCODING=UTF8 "$@"; }
psql_local()  { en_postgres PGOPTIONS='-c client_min_messages=warning' psql -X -v ON_ERROR_STOP=1 -Atq "$@"; }

pg_actif()     { systemctl is-active --quiet "$UNITE"; }
est_replique() { [ -f "$DATA/standby.signal" ]; }

attendre_pg() {
  local i
  for ((i = 0; i < 60; i++)); do
    "$PGBIN/pg_isready" -q -h 127.0.0.1 && return 0
    sleep 1
  done
  echo "PostgreSQL ne répond pas sur $MOI" >&2
  return 1
}

# Vrai si l'autre base répond ET accepte les écritures (n'est pas en recovery)
pair_est_primaire() {
  [ -n "$PAIR_IP" ] || return 1
  [ "$(en_postgres psql -X -Atq "host=$PAIR_IP dbname=postgres user=replicateur connect_timeout=3" \
        -c 'SELECT NOT pg_is_in_recovery()' 2>/dev/null)" = t ]
}
