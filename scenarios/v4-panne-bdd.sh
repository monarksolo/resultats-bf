#!/usr/bin/env bash
# V4 — Panne de la base primaire.
# Attendu : le service renvoie proprement 503 sur /sante (JSON), jamais une page
# blanche ni une erreur de connexion brute ; puis la bascule sur la réplique.
# Mesure : temps total de la procédure de bascule.
#
# Usage : scenarios/v4-panne-bdd.sh [PRIMAIRE] [REPLIQUE]   (défaut : bdd1 bdd2)
#         REINTEGRER=1 pour relancer ensuite l'ancienne primaire, qui redevient réplique.
source "$(dirname "$0")/commun.sh"
PRIMAIRE=${1:-bdd1}; REPLIQUE=${2:-bdd2}
JOURNAL=mesures/v4-$HORODATAGE.log

{
  titre "V4 — Panne de la base primaire $PRIMAIRE — $(date '+%F %T')"
  echo "Avant la panne : GET /sante -> $(curl -s --max-time 3 -w ' [HTTP %{http_code}]' "$URL/sante")"
  t0=$(maintenant)
  vagrant halt "$PRIMAIRE" 2>&1 | tr -d '\r'
  echo "$PRIMAIRE arrêtée en $(ecart "$t0" "$(maintenant)") s"

  echo "Réponses du service pendant la panne (une par seconde) :"
  for ((i = 0; i < 8; i++)); do
    printf '  t+%ss  /sante -> %s\n' "$i" "$(curl -s --max-time 5 -w ' [HTTP %{http_code}]' "$URL/sante")"
    sleep 1
  done
  printf '  /resultat -> %s\n' "$(curl -s --max-time 5 -w ' [HTTP %{http_code}]' "$URL/resultat?matricule=BF000042")"
} 2>&1 | tee "$JOURNAL"

titre "Procédure de bascule (scripts/bascule-bdd.sh $REPLIQUE)" | tee -a "$JOURNAL"
scripts/bascule-bdd.sh "$REPLIQUE" 2>&1 | tee -a "$JOURNAL"
echo "Après bascule : /resultat -> $(curl -s --max-time 5 "$URL/resultat?matricule=BF000042")" | tee -a "$JOURNAL"

if [ "${REINTEGRER:-0}" = 1 ]; then
  titre "Réintégration : vagrant up $PRIMAIRE (redevient réplique de $REPLIQUE)" | tee -a "$JOURNAL"
  vagrant up "$PRIMAIRE" 2>&1 | tr -d '\r' | grep -E "\[$PRIMAIRE\]" | tee -a "$JOURNAL"
fi
echo "Journal : $JOURNAL"
