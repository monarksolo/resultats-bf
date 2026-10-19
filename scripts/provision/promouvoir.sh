#!/usr/bin/env bash
# Promotion de la réplique LOCALE en primaire (exécuté dans la VM par scripts/bascule-bdd.sh).
# Garde-fou : refuse de promouvoir si l'autre base répond encore comme primaire,
# sauf FORCER=1 — deux primaires simultanées divergeraient (« split brain »).

source /vagrant/scripts/provision/commun.sh
source /vagrant/scripts/provision/pg.sh

if ! est_replique; then
  log "déjà primaire : rien à promouvoir"
  exit 0
fi
if pair_est_primaire && [ "${FORCER:-0}" != 1 ]; then
  echo "REFUS : la primaire $PAIR_IP répond encore. Arrêtez-la d'abord (vagrant halt), ou FORCER=1." >&2
  exit 2
fi

debut=$(date +%s.%N)
psql_local -c "SELECT pg_promote(wait => true, wait_seconds => 30)" >/dev/null
until [ "$(psql_local -c 'SELECT pg_is_in_recovery()')" = f ]; do sleep 0.1; done
fin=$(date +%s.%N)
log "promue primaire en $(awk -v a="$debut" -v b="$fin" 'BEGIN {printf "%.2f", b - a}') s"
