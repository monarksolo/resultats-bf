#!/usr/bin/env bash
# V6 — Panne du répartiteur actif (extension E1).
# Attendu : le service reste joignable à la MÊME adresse (IP virtuelle VRRP).
# Mesure : temps de reprise après bascule VRRP.
#
# Usage : scenarios/v6-panne-lb.sh        RETABLIR=0 pour laisser lb1 éteint.
source "$(dirname "$0")/commun.sh"
extension E1 || { echo "L'extension E1 n'est pas active (EXTENSIONS dans .env)."; exit 1; }
URL="http://$VIP"
BRUT=mesures/v6-$HORODATAGE-brut.log
JOURNAL=mesures/v6-$HORODATAGE.log

{
  titre "V6 — Panne de lb1 sous charge, adresse virtuelle $VIP — $(date '+%F %T')"
  charge_debut "$BRUT" /info
  sleep 5
  echo "t+$(ecart "$CHARGE_T0" "$(maintenant)") s : vagrant halt lb1"
  vagrant halt lb1 2>&1 | tr -d '\r'
  echo "t+$(ecart "$CHARGE_T0" "$(maintenant)") s : lb1 arrêté ; la charge continue 15 s"
  sleep 15
  charge_fin
  charge_bilan "$BRUT"
  echo "Porteur de l'adresse virtuelle : $(vagrant ssh lb2 -c "ip -o -4 addr | grep -q ' $VIP/' && echo lb2 || echo 'pas lb2'" 2>/dev/null | tr -d '\r')"
} 2>&1 | tee "$JOURNAL"
echo "Journal : $JOURNAL — requêtes brutes : $BRUT"

if [ "${RETABLIR:-1}" = 1 ]; then
  titre "Rétablissement : vagrant up lb1 (reprend l'adresse virtuelle)"
  vagrant up lb1
fi
