#!/usr/bin/env bash
# Pilote un serveur applicatif dans HAProxy via l'API d'exécution (exécuté DANS lb1/lb2).
# Usage : haproxy-serveur.sh drain SERVEUR   -> plus de nouvelles requêtes, attend 0 session en cours
#         haproxy-serveur.sh ready SERVEUR   -> remet en service, attend que la sonde le voie UP
# Appelé par scripts/deployer.sh (E4) : une seule commande « vagrant ssh » par étape et
# par répartiteur, car chaque « vagrant ssh » coûte plusieurs secondes sous Windows.

set -euo pipefail
ACTION=${1:?drain|ready}; SERVEUR=${2:?serveur}
SOCKET=/run/haproxy/admin.sock

api()  { echo "$1" | socat stdio "$SOCKET"; }
stat() { api "show stat" | awk -F, -v s="$SERVEUR" -v c="$1" '$1 == "applis" && $2 == s {print $c}'; }   # 5 = sessions, 18 = état

api "set server applis/$SERVEUR state $ACTION" >/dev/null
for ((i = 0; i < 30; i++)); do
  case "$ACTION" in
    drain) [ "$(stat 5)" = 0 ] && break ;;
    ready) [ "$(stat 18)" = UP ] && break ;;
  esac
  sleep 1
done
echo "$(hostname) : $SERVEUR état $(stat 18), sessions en cours $(stat 5)"
