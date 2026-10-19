#!/usr/bin/env bash
# V5 — Reconstruction intégrale (R1) : vagrant destroy -f puis vagrant up,
# sans aucune intervention. Mesure : durée totale de la reconstruction.
#
# Usage : scenarios/v5-reconstruction.sh --oui     (DÉTRUIT toutes les VM)
source "$(dirname "$0")/commun.sh"
[ "${1:-}" = --oui ] || { echo "Ce scénario détruit toutes les VM. Relancez avec --oui pour confirmer."; exit 1; }
JOURNAL=mesures/v5-$HORODATAGE.log

{
  titre "V5 — Reconstruction intégrale — $(date '+%F %T')"
  t0=$(maintenant)
  vagrant destroy -f 2>&1 | tr -d '\r'
  t1=$(maintenant)
  vagrant up 2>&1 | tr -d '\r'
  t2=$(maintenant)
  echo
  echo "Destruction       : $(ecart "$t0" "$t1") s"
  echo "Construction      : $(ecart "$t1" "$t2") s"
  echo "DURÉE TOTALE      : $(ecart "$t0" "$t2") s"
  echo
  echo "Vérification : /sante -> $(code_http "$URL/sante") ; /resultat -> $(curl -s --max-time 3 "$URL/resultat?matricule=BF000042")"
} 2>&1 | tee "$JOURNAL"
"$(dirname "$0")/v1-repartition.sh"
echo "Journal : $JOURNAL"
