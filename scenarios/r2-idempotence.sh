#!/usr/bin/env bash
# R2 — Idempotence : « vagrant provision » rejoué deux fois de suite ne modifie
# rien et n'échoue pas. On compare l'empreinte de tous les fichiers de /etc et
# /opt de chaque VM entre les deux rejeux, et l'on compte les fichiers réécrits.
source "$(dirname "$0")/commun.sh"
JOURNAL=mesures/r2-$HORODATAGE.log
VMS=$(vagrant status --machine-readable | awk -F, '$3 == "state" && $4 == "running" {print $2}')
empreintes() {
  for vm in $VMS; do
    vagrant ssh "$vm" -c "sudo find /etc /opt -xdev -type f -print0 | sort -z | sudo xargs -0 sha256sum" 2>/dev/null \
      | tr -d '\r' | sed "s|^|$vm |"
  done
}

{
  titre "R2 — Idempotence — $(date '+%F %T') — VM : $(echo $VMS)"
  echo "Rejeu n° 1"
  vagrant provision > mesures/r2-$HORODATAGE-rejeu1.log 2>&1 || { echo "ÉCHEC du rejeu n° 1"; exit 1; }
  empreintes > mesures/r2-$HORODATAGE-avant.sha
  echo "Rejeu n° 2"
  vagrant provision > mesures/r2-$HORODATAGE-rejeu2.log 2>&1 || { echo "ÉCHEC du rejeu n° 2"; exit 1; }
  empreintes > mesures/r2-$HORODATAGE-apres.sha

  echo "Fichiers réécrits pendant le rejeu n° 2 : $(grep -c 'fichier mis à jour' mesures/r2-$HORODATAGE-rejeu2.log || true)"
  if diff mesures/r2-$HORODATAGE-avant.sha mesures/r2-$HORODATAGE-apres.sha; then
    echo "RÉSULTAT : aucune différence dans /etc et /opt — provisionnement idempotent."
  else
    echo "RÉSULTAT : différences ci-dessus."
  fi
} 2>&1 | tee "$JOURNAL"
echo "Journal : $JOURNAL"
