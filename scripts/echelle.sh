#!/usr/bin/env bash
# R3 — Ajuste le nombre de serveurs applicatifs, à chaud.
#
# Usage : scripts/echelle.sh N        (2 <= N <= 9)
#
# Ajout   : NB_APP=N vagrant up  -> crée les nouveaux serveurs ; les scripts
#           « run: always » régénèrent la configuration du répartiteur, de la base
#           et de Prometheus depuis config/noeuds.yml (rechargement sans coupure).
# Retrait : la configuration est d'abord régénérée SANS les serveurs en trop
#           (ils ne reçoivent plus de trafic), puis ces serveurs sont détruits.
# La valeur est enregistrée dans .env pour que les « vagrant up » suivants la gardent.

set -euo pipefail
cd "$(dirname "$0")/.."
N=${1:?Usage : scripts/echelle.sh N}
[[ $N =~ ^[2-9]$ ]] || { echo "N doit être compris entre 2 et 9" >&2; exit 1; }

# Serveurs applicatifs existants, quel que soit le NB_APP courant
EN_TROP=$(NB_APP=9 vagrant status --machine-readable \
  | awk -F, -v n="$N" '$3 == "state" && $2 ~ /^app[0-9]$/ && $4 != "not_created" && substr($2, 4) + 0 > n {print $2}')

sed -i.bak "s/^NB_APP=.*/NB_APP=$N/" .env && rm -f .env.bak
echo "NB_APP=$N enregistré dans .env"

NB_APP=$N vagrant up
if [ -n "$EN_TROP" ]; then
  echo "Retrait de : $EN_TROP"
  NB_APP=9 vagrant destroy -f $EN_TROP
fi
NB_APP=$N vagrant status
