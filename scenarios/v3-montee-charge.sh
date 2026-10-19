#!/usr/bin/env bash
# V3 — Montée en charge : ab -n 2000 -c 50, avec N=2 puis N=4 serveurs applicatifs.
# Mesure : requêtes par seconde dans les deux configurations.
#
# Usage : scenarios/v3-montee-charge.sh           mesure la configuration actuelle
#         scenarios/v3-montee-charge.sh --comparer  N=2, passage à N=4, N=4, retour à N=2
# REPETITIONS=3 par défaut : on garde chaque mesure, et la médiane.
#
# Honnêteté des mesures : toutes les VM partagent le processeur de l'hôte, et
# l'injecteur (ab) tourne lui-même dans une VM. Le débit ne doublera pas.
source "$(dirname "$0")/commun.sh"
REQ=${REQ:-2000}; CONC=${CONC:-50}; REPETITIONS=${REPETITIONS:-3}
CHEMIN='/resultat?matricule=BF000042'
JOURNAL=mesures/v3-$HORODATAGE.log

mesurer() {   # affiche « N  rps1 rps2 ... | médiane »
  local inj cible n rps=() r
  inj=$(injecteur); cible=$(cible_interne); n=$(noeuds_role app | wc -l)
  echo "--- N=$n serveurs ; injecteur : $inj ; cible : $cible$CHEMIN"
  vagrant ssh "$inj" -c "ab -q -n 200 -c 10 '$cible$CHEMIN' >/dev/null" 2>/dev/null || true   # préchauffage
  for ((k = 1; k <= REPETITIONS; k++)); do
    sortie=$(vagrant ssh "$inj" -c "ab -n $REQ -c $CONC '$cible$CHEMIN'" 2>/dev/null | tr -d '\r')
    echo "$sortie" | grep -E "^(Complete requests|Failed requests|Non-2xx|Requests per second|Time per request|Percentage|  50%|  95%|  99%)"
    r=$(echo "$sortie" | awk '/^Requests per second/ {print $4}')
    rps+=("$r")
  done
  printf 'RÉSULTAT N=%s : %s req/s (médiane : %s)\n' "$n" "${rps[*]}" \
    "$(printf '%s\n' "${rps[@]}" | sort -n | awk '{a[NR] = $1} END {print a[int((NR + 1) / 2)]}')"
}

{
  titre "V3 — Montée en charge : ab -n $REQ -c $CONC — $(date '+%F %T')"
  if [ "${1:-}" = --comparer ]; then
    scripts/echelle.sh 2 >/dev/null
    vagrant status >/dev/null
    mesurer
    titre "Passage à N=4"
    scripts/echelle.sh 4 2>&1 | tail -n 12
    vagrant status >/dev/null
    sleep 5
    mesurer
    titre "Retour à N=2"
    scripts/echelle.sh 2 >/dev/null
    vagrant status >/dev/null
  else
    mesurer
  fi
} 2>&1 | tee "$JOURNAL"
echo "Journal : $JOURNAL"
