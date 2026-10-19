#!/usr/bin/env bash
# Fonctions partagées par tous les scripts de provisionnement.
# Toutes sont idempotentes : rejouer un script ne modifie rien s'il n'y a rien à faire.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PROJET=/vagrant
NOEUDS_YML=$PROJET/config/noeuds.yml
GENERER="python3 $PROJET/scripts/provision/generer.py"
CACHE_APT=$PROJET/.cache/apt
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold)

log() { echo "[$(hostname)] $*"; }

# extension_active E1  ->  vrai si l'extension figure dans $EXTENSIONS
extension_active() { [[ ",${EXTENSIONS:-}," == *",$1,"* ]]; }

# installer_paquets p1 p2 ...
# Un seul apt-get install groupé par machine. Les .deb déjà téléchargés par une
# autre VM sont repris de /vagrant/.cache/apt : on ne télécharge pas quatre fois
# la même chose derrière une connexion lente.
installer_paquets() {
  local manquants=() p
  for p in "$@"; do
    [ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" = "install ok installed" ] || manquants+=("$p")
  done
  [ ${#manquants[@]} -eq 0 ] && return 0

  log "installation : ${manquants[*]}"
  mkdir -p "$CACHE_APT"
  cp -n "$CACHE_APT"/*.deb /var/cache/apt/archives/ 2>/dev/null || true
  apt-get "${APT_OPTS[@]}" update
  apt-get "${APT_OPTS[@]}" install --no-install-recommends "${manquants[@]}"
  cp -n /var/cache/apt/archives/*.deb "$CACHE_APT"/ 2>/dev/null || true
}

# deposer CIBLE [MODE] [PROPRIO:GROUPE] < contenu
# Écrit le fichier seulement si son contenu change. Renvoie 0 si modifié, 1 sinon :
# à utiliser dans un « if » pour ne recharger un service qu'en cas de changement.
deposer() {
  local cible=$1 mode=${2:-644} proprio=${3:-root:root} tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$cible" ] && cmp -s "$tmp" "$cible"; then
    rm -f "$tmp"
    chmod "$mode" "$cible"; chown "$proprio" "$cible"
    return 1
  fi
  install -D -m "$mode" -o "${proprio%%:*}" -g "${proprio##*:}" "$tmp" "$cible"
  rm -f "$tmp"
  log "fichier mis à jour : $cible"
  return 0
}

# Lecture de la source unique de vérité
noeud_ip()     { $GENERER ip "$1"; }
noeuds_role()  { $GENERER liste "$1"; }      # lignes « nom ip »
adresse_vip()  { $GENERER vip; }
mon_ip()       { noeud_ip "$(hostname)"; }

# Nom de l'interface qui porte l'adresse privée de la machine (eth1, enp0s8…).
# Attention aux tubes : avec pipefail, un lecteur qui s'arrête tôt (awk exit,
# grep -q) fait échouer l'écrivain (SIGPIPE) ; on lit donc toujours tout.
interface_privee() {
  ip -o -4 addr show | awk -v ip="$(mon_ip)" '{split($4, a, "/")} a[1] == ip && !vu {print $2; vu = 1}'
}

# Bloc /etc/hosts engendré depuis noeuds.yml (remplacé, jamais ajouté avec >>)
maj_hosts() {
  local debut="# --- RESULTATS-BF debut ---" fin="# --- RESULTATS-BF fin ---"
  {
    sed "/^$debut\$/,/^$fin\$/d" /etc/hosts
    echo "$debut"
    $GENERER hosts
    echo "$fin"
  } | deposer /etc/hosts 644 || true
}

# Exportateur de métriques système quand l'extension E2 est active
paquets_supervision() { extension_active E2 && echo prometheus-node-exporter || true; }

activer_service() {
  systemctl enable --quiet "$1"
  systemctl is-active --quiet "$1" || systemctl start "$1"
}

# attendre_http URL [SECONDES] [CODE]  — attend qu'une URL réponde le code voulu
attendre_http() {
  local url=$1 delai=${2:-60} code=${3:-200} i
  for ((i = 0; i < delai; i++)); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url")" = "$code" ] && return 0
    sleep 1
  done
  return 1
}

# Paquets communs à toutes les machines (python3-yaml lit noeuds.yml)
PAQUETS_BASE=(python3 python3-yaml curl ca-certificates)

[ -f "$NOEUDS_YML" ] || { echo "config/noeuds.yml absent : lancez les commandes vagrant depuis la racine du projet." >&2; exit 1; }
