#!/usr/bin/env bash
# Répartiteur de charge : HAProxy (lb1, lb2) + keepalived/VRRP si l'extension E1 est active.
#
# La liste des serveurs applicatifs n'est écrite nulle part à la main : elle est
# engendrée depuis config/noeuds.yml (generer.py haproxy). Le script étant rejoué
# à chaque « vagrant up », NB_APP=4 vagrant up met à jour un répartiteur déjà
# en marche, sans coupure (reload).

source /vagrant/scripts/provision/commun.sh

PAQUETS=("${PAQUETS_BASE[@]}" haproxy socat apache2-utils $(paquets_supervision))
extension_active E1 && PAQUETS+=(keepalived)
installer_paquets "${PAQUETS[@]}"
maj_hosts

# --- HAProxy
# Page d'erreur 503 propre (JSON) quand plus aucun serveur n'est sain
# HAProxy lit ces fichiers au chargement : tout changement impose un rechargement.
RECHARGER=0
printf 'HTTP/1.0 503 Service Unavailable\r\nCache-Control: no-cache\r\nConnection: close\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{"erreur":"service momentanément indisponible","code":503}\n' \
  | deposer /etc/haproxy/errors/503-resultats.http 644 && RECHARGER=1
# Interface graphique et carte de la plateforme (engendrée depuis noeuds.yml)
deposer /etc/haproxy/www/index.html 644 < /vagrant/app/interface.html && RECHARGER=1
$GENERER json | deposer /etc/haproxy/www/noeuds.json 644 && RECHARGER=1

# Exportateur Prometheus intégré à HAProxy, s'il est compilé dans le paquet
if haproxy -vv 2>/dev/null | grep 'prometheus-exporter' >/dev/null; then export HAPROXY_PROMEX=1; else export HAPROXY_PROMEX=0; fi

NOUVELLE=$(mktemp)
$GENERER haproxy > "$NOUVELLE"
haproxy -c -q -f "$NOUVELLE" || { echo "Configuration HAProxy engendrée invalide" >&2; cat "$NOUVELLE"; exit 1; }
deposer /etc/haproxy/haproxy.cfg 644 < "$NOUVELLE" && RECHARGER=1
rm -f "$NOUVELLE"
systemctl enable --quiet haproxy
if ! systemctl is-active --quiet haproxy; then
  systemctl start haproxy
elif [ "$RECHARGER" = 1 ]; then
  systemctl reload haproxy
fi
log "serveurs applicatifs déclarés : $(noeuds_role app | awk '{print $1}' | paste -sd' ')"

# --- keepalived (E1) : adresse IP virtuelle partagée en VRRP
if extension_active E1; then
  IFACE=$(interface_privee)
  [ -n "$IFACE" ] || { echo "Interface du réseau privé introuvable" >&2; exit 1; }
  if $GENERER keepalived "$(hostname)" "$IFACE" | deposer /etc/keepalived/keepalived.conf 600; then
    systemctl enable --quiet keepalived
    systemctl restart keepalived
  else
    activer_service keepalived
  fi
  # keepalived attend 2 vérifications réussies de HAProxy avant de prendre l'adresse
  porte_vip() { ip -o -4 addr show dev "$IFACE" | grep " $(adresse_vip)/" >/dev/null; }
  for ((i = 0; i < 10; i++)); do porte_vip && break; sleep 1; done
  if porte_vip; then
    log "VRRP : je porte l'adresse virtuelle $(adresse_vip)"
  else
    log "VRRP : passif, l'adresse virtuelle $(adresse_vip) est portée par le pair"
  fi
fi

attendre_http http://127.0.0.1:8404/stats 15 || { echo "HAProxy ne répond pas" >&2; exit 1; }
