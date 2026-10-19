#!/usr/bin/env bash
# Supervision (extension E2) : Prometheus + Grafana sur la machine obs.
# Les cibles de collecte sont engendrées depuis config/noeuds.yml : un serveur
# ajouté avec NB_APP apparaît tout seul dans Prometheus et dans le tableau de bord.

source /vagrant/scripts/provision/commun.sh

# Dépôt officiel Grafana (gratuit, public), déclaré AVANT l'unique apt-get install
install -d -m 755 /etc/apt/keyrings
command -v gpg >/dev/null || installer_paquets gnupg
if [ ! -s /etc/apt/keyrings/grafana.gpg ]; then
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | deposer /etc/apt/sources.list.d/grafana.list 644 || true

# apache2-utils : obs sert aussi d'injecteur de charge (ab) pour les scénarios
installer_paquets "${PAQUETS_BASE[@]}" prometheus prometheus-node-exporter grafana apache2-utils
maj_hosts

# --- Prometheus
NOUVELLE=$(mktemp)
$GENERER prometheus > "$NOUVELLE"
promtool check config "$NOUVELLE" >/dev/null || { echo "Configuration Prometheus invalide" >&2; cat "$NOUVELLE"; exit 1; }
if deposer /etc/prometheus/prometheus.yml 644 < "$NOUVELLE"; then
  systemctl enable --quiet prometheus
  systemctl restart prometheus
else
  activer_service prometheus
fi
rm -f "$NOUVELLE"

# --- Grafana : source de données et tableau de bord provisionnés par fichiers
REDEMARRER=0
deposer /etc/grafana/provisioning/datasources/resultats.yml 640 root:grafana <<'EOF' && REDEMARRER=1
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    jsonData:
      timeInterval: 5s
EOF
deposer /etc/grafana/provisioning/dashboards/resultats.yml 640 root:grafana <<'EOF' && REDEMARRER=1
apiVersion: 1
providers:
  - name: resultats-bf
    folder: RESULTATS-BF
    type: file
    options:
      path: /var/lib/grafana/dashboards
EOF
deposer /var/lib/grafana/dashboards/resultats-bf.json 644 grafana:grafana \
  < /vagrant/config/grafana/resultats-bf.json && REDEMARRER=1
if deposer /etc/systemd/system/grafana-server.service.d/resultats.conf 600 <<EOF
[Service]
Environment=GF_SECURITY_ADMIN_PASSWORD=$GRAFANA_MDP_ADMIN
Environment=GF_AUTH_ANONYMOUS_ENABLED=true
Environment=GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
Environment=GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/resultats-bf.json
# Aucun appel sortant au démarrage : pas de plugins préinstallés depuis grafana.com,
# pas de vérification de mises à jour ni de télémétrie (connexion lente, VM de 768 Mo)
Environment=GF_PLUGINS_PREINSTALL_DISABLED=true
Environment=GF_ANALYTICS_REPORTING_ENABLED=false
Environment=GF_ANALYTICS_CHECK_FOR_UPDATES=false
Environment=GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false
Environment=GF_NEWS_NEWS_FEED_ENABLED=false
EOF
then
  systemctl daemon-reload
  REDEMARRER=1
fi

systemctl enable --quiet grafana-server
if ! systemctl is-active --quiet grafana-server; then
  systemctl start grafana-server
elif [ "$REDEMARRER" = 1 ]; then
  systemctl restart grafana-server
fi

attendre_http http://127.0.0.1:9090/-/ready 60 || { echo "Prometheus ne répond pas" >&2; exit 1; }
# Premier démarrage : Grafana applique ~700 migrations de sa base (environ 2 min sur 1 vCPU)
attendre_http http://127.0.0.1:3000/api/health 300 || { echo "Grafana ne répond pas" >&2; journalctl -u grafana-server -n 20 --no-pager; exit 1; }
log "Grafana : http://$(mon_ip):3000  —  Prometheus : http://$(mon_ip):9090/targets"
