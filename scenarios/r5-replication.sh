#!/usr/bin/env bash
# R5 — Réplication en flux : une écriture sur la primaire est visible sur la réplique.
source "$(dirname "$0")/commun.sh"
JOURNAL=mesures/r5-$HORODATAGE.log
MATRICULE="TEST$(date +%s)"

sql() {   # sql VM "requête"
  vagrant ssh "$1" -c "sudo -u postgres psql -X -Atq -d resultats -c \"$2\"" 2>/dev/null | tr -d '\r'
}

{
  titre "R5 — Réplication — $(date '+%F %T')"
  PRIMAIRE=""; REPLIQUE=""
  for vm in $(noeuds_role bdd) $(noeuds_role replique); do
    case "$(sql "$vm" 'SELECT pg_is_in_recovery()')" in
      f) PRIMAIRE=$vm ;;
      t) REPLIQUE=$vm ;;
    esac
  done
  [ -n "$PRIMAIRE" ] && [ -n "$REPLIQUE" ] || { echo "Primaire ($PRIMAIRE) ou réplique ($REPLIQUE) introuvable"; exit 1; }
  echo "Primaire : $PRIMAIRE   Réplique : $REPLIQUE"
  echo "État de la réplication vu de la primaire :"
  sql "$PRIMAIRE" "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication"

  echo "Insertion sur $PRIMAIRE du matricule $MATRICULE"
  sql "$PRIMAIRE" "INSERT INTO resultats VALUES ('$MATRICULE', 'TEST REPLICATION', 'D', 12.5, true)"
  echo "Lecture sur $REPLIQUE :"
  sql "$REPLIQUE" "SELECT * FROM resultats WHERE matricule = '$MATRICULE'"
  sql "$PRIMAIRE" "DELETE FROM resultats WHERE matricule = '$MATRICULE'"
} 2>&1 | tee "$JOURNAL"
echo "Journal : $JOURNAL"
