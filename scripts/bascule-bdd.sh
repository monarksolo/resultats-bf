#!/usr/bin/env bash
# R6 — Procédure de bascule de la base, exécutable et chronométrée (sur l'hôte).
#
# Usage : scripts/bascule-bdd.sh [REPLIQUE]      (défaut : bdd2)
#
# 1. vérifie que l'ancienne primaire est bien hors service (sinon refus) ;
# 2. promeut la réplique (pg_promote) ;
# 3. attend que le service public réponde de nouveau 200 sur /sante.
# Aucune reconfiguration des serveurs applicatifs : libpq retrouve seule la base
# qui accepte les écritures (target_session_attrs=read-write).
#
# Réintégration ensuite : « vagrant up bdd1 » — le provisionnement constate que
# bdd2 est primaire et reconstruit bdd1 en réplique (pg_basebackup).

source "$(dirname "$0")/../scenarios/commun.sh"
REPLIQUE=${1:-bdd2}
JOURNAL=mesures/bascule-$HORODATAGE.log

{
  titre "Bascule de la base vers $REPLIQUE — $(date '+%F %T')"
  t0=$(maintenant)
  echo "Avant : /sante -> $(code_http "$URL/sante")"

  vagrant ssh "$REPLIQUE" -c "sudo bash /vagrant/scripts/provision/promouvoir.sh" 2>&1 | tr -d '\r'
  t1=$(maintenant)

  until [ "$(code_http "$URL/sante")" = 200 ]; do
    if [ "$(ecart "$t1" "$(maintenant)" | cut -d. -f1)" -ge 60 ]; then
      echo "ÉCHEC : /sante ne répond pas 200 après 60 s"; exit 1
    fi
    sleep 0.2
  done
  t2=$(maintenant)

  echo "Après : /sante -> 200"
  echo "Promotion (vagrant ssh compris)    : $(ecart "$t0" "$t1") s"
  echo "Retour du service après promotion  : $(ecart "$t1" "$t2") s"
  echo "DURÉE TOTALE DE LA BASCULE         : $(ecart "$t0" "$t2") s"
} | tee "$JOURNAL"
echo "Journal : $JOURNAL"
