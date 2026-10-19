#!/usr/bin/env bash
# V2 — Panne d'un serveur applicatif pendant une charge continue.
# Attendu : service toujours disponible ; aucune erreur au-delà de 5 s.
# Mesures : nombre de requêtes perdues, durée de la période dégradée.
#
# Usage : scenarios/v2-panne-app.sh [SERVEUR]   (défaut app1 ; PARALLELE=4 boucles curl)
#         RETABLIR=0 pour laisser le serveur éteint à la fin.
source "$(dirname "$0")/commun.sh"
CIBLE=${1:-app1}
BRUT=mesures/v2-$HORODATAGE-brut.log
JOURNAL=mesures/v2-$HORODATAGE.log

{
  titre "V2 — Panne de $CIBLE sous charge ($URL, ${PARALLELE:-4} clients) — $(date '+%F %T')"
  charge_debut "$BRUT"
  sleep 5
  echo "t+$(ecart "$CHARGE_T0" "$(maintenant)") s : vagrant halt $CIBLE"
  vagrant halt "$CIBLE" 2>&1 | tr -d '\r'
  echo "t+$(ecart "$CHARGE_T0" "$(maintenant)") s : $CIBLE arrêté ; la charge continue 15 s"
  sleep 15
  charge_fin
  charge_bilan "$BRUT"
  echo "Répartition actuelle :"
  for ((i = 0; i < 6; i++)); do curl -s --max-time 3 "$URL/info"; echo; done
} 2>&1 | tee "$JOURNAL"
echo "Journal : $JOURNAL — requêtes brutes : $BRUT"

if [ "${RETABLIR:-1}" = 1 ]; then
  titre "Rétablissement : vagrant up $CIBLE"
  vagrant up "$CIBLE"
fi
