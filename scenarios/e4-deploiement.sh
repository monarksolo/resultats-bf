#!/usr/bin/env bash
# E4 — Déploiement sans coupure : mise à jour complète pendant une charge continue.
# Attendu : pas une seule requête en erreur.
#
# Préparation : modifiez app/resultats.py (par exemple VERSION = "1.1.0"), puis
#   scenarios/e4-deploiement.sh
source "$(dirname "$0")/commun.sh"
BRUT=mesures/e4-$HORODATAGE-brut.log
JOURNAL=mesures/e4-$HORODATAGE.log

{
  titre "E4 — Déploiement serveur par serveur sous charge — $(date '+%F %T')"
  echo "Version servie avant : $(curl -s --max-time 3 "$URL/info")"
  charge_debut "$BRUT"
  scripts/deployer.sh
  sleep 3
  charge_fin
  charge_bilan "$BRUT"
} 2>&1 | tee "$JOURNAL"
echo "Journal : $JOURNAL — requêtes brutes : $BRUT"
