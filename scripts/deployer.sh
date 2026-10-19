#!/usr/bin/env bash
# E4 — Déploiement sans coupure : mise à jour de l'application serveur par serveur.
#
# Usage : scripts/deployer.sh
# Pour chaque serveur applicatif (lus dans config/noeuds.yml) :
#   1. le serveur est mis en « drain » sur tous les répartiteurs : plus de nouvelles
#      requêtes, et l'on attend la fin de celles en cours ;
#   2. le code de app/ est déployé (vagrant provision : redémarrage seulement si changé) ;
#   3. le serveur est remis en service et l'on attend que la sonde /sante le voie UP.
# Les autres serveurs absorbent le trafic pendant ce temps ; HAProxy rejoue en
# outre sur un autre serveur toute requête interrompue (retry-on + redispatch).
#
# Les étapes 1 et 3 s'exécutent dans chaque répartiteur (scripts/provision/haproxy-serveur.sh) :
# une seule commande « vagrant ssh » par étape, car chacune coûte cher sous Windows.

source "$(dirname "$0")/../scenarios/commun.sh"
LBS=$(noeuds_role lb)

piloter() {   # piloter drain|ready SERVEUR  — sur tous les répartiteurs
  for lb in $LBS; do
    vagrant ssh "$lb" -c "sudo bash /vagrant/scripts/provision/haproxy-serveur.sh $1 $2" 2>/dev/null | tr -d '\r'
  done
}

t0=$(maintenant)
for app in $(noeuds_role app); do
  titre "Mise à jour de $app"
  piloter drain "$app"
  vagrant provision "$app" 2>&1 | tr -d '\r' | grep -E "\[$app\]|Error|error" || true
  piloter ready "$app"
done
titre "Déploiement terminé en $(ecart "$t0" "$(maintenant)") s"
for ((i = 0; i < 6; i++)); do curl -s --max-time 3 "$URL/info"; echo; done
