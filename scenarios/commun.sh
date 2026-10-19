#!/usr/bin/env bash
# Fonctions partagées par les scénarios et procédures exécutés SUR L'HÔTE
# (Linux, macOS, ou Git Bash sous Windows). Prérequis : vagrant, curl, awk.

set -euo pipefail
RACINE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$RACINE"
mkdir -p mesures
HORODATAGE=$(date +%Y%m%d-%H%M%S)

titre() { printf '\n=== %s ===\n' "$*"; }
maintenant() { date +%s.%N; }
ecart() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.2f", b - a}'; }

# Lecture de la source unique de vérité (engendrée par le Vagrantfile).
# « vagrant status » la régénère avec les paramètres courants (.env + environnement).
vagrant status >/dev/null
noeuds_role() { awk -v r="$1" '/- nom:/ {n = $3} $1 == "role:" && $2 == r {print n}' config/noeuds.yml; }
ip_de()       { awk -v n="$1" '/- nom:/ {o = ($3 == n)} o && $1 == "ip:" {print $2; exit}' config/noeuds.yml; }
extension()   { grep -qE "^- $1\$" config/noeuds.yml; }
VIP=$(awk '$1 == "vip:" {print $2}' config/noeuds.yml)

# Adresse publique du service : l'IP virtuelle VRRP si E1, sinon le port redirigé de lb1
if extension E1; then URL="http://$VIP"; else URL="http://127.0.0.1:8080"; fi
URL=${URL_SERVICE:-$URL}

code_http() { curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-3}" "$1" || true; }

# Machine qui lance les tests de charge (ab) : obs si E2, sinon lb1.
# Elle partage le CPU de l'hôte avec les autres VM : à mentionner dans le dossier.
injecteur() { if extension E2; then echo obs; else echo lb1; fi; }
cible_interne() { if extension E1; then echo "http://$VIP"; else echo "http://$(ip_de lb1)"; fi; }

# --- Charge continue pendant une panne : PARALLELE boucles de curl --------------
# charge_debut FICHIER [CHEMIN]  /  charge_fin  /  charge_bilan FICHIER
charge_debut() {
  CHARGE_FICHIER=$1; CHARGE_STOP=$(mktemp -u); : > "$CHARGE_FICHIER"
  local chemin=${2:-/resultat?matricule=BF000042} i
  for ((i = 0; i < ${PARALLELE:-4}; i++)); do
    ( while [ ! -e "$CHARGE_STOP" ]; do
        t=$(maintenant)
        c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL$chemin" || true)
        echo "$t $c"
      done >> "$CHARGE_FICHIER" ) &
  done
  CHARGE_T0=$(maintenant)
}
charge_fin() { touch "$CHARGE_STOP"; wait; rm -f "$CHARGE_STOP"; }
charge_bilan() {
  sort -n "$1" | awk -v t0="$CHARGE_T0" '
    { total++; if ($2 != "200") { err++; codes[$2]++; if (!premiere) premiere = $1; derniere = $1 } }
    END {
      printf "Requêtes envoyées      : %d\n", total
      printf "Requêtes en erreur     : %d (%.2f %%)\n", err, total ? 100 * err / total : 0
      for (c in codes) printf "   code %-4s : %d\n", (c == "000" ? "000 (pas de réponse)" : c), codes[c]
      if (err) {
        printf "Première erreur        : t+%.2f s\n", premiere - t0
        printf "Dernière erreur        : t+%.2f s\n", derniere - t0
        printf "Période dégradée       : %.2f s\n", derniere - premiere
      } else print "Période dégradée       : aucune"
    }'
}
