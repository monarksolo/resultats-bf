#!/usr/bin/env bash
# Serveur applicatif sans état : service Python (app/resultats.py) sous systemd.
# Rejoué par scripts/deployer.sh pour la mise à jour serveur par serveur (E4) :
# le service n'est redémarré que si le code ou sa configuration a changé.

source /vagrant/scripts/provision/commun.sh

installer_paquets "${PAQUETS_BASE[@]}" python3-psycopg2 $(paquets_supervision)
maj_hosts

id resultats &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin resultats

# Les adresses des bases viennent de la source unique de vérité ; libpq
# choisira seule celle qui accepte les écritures (target_session_attrs).
PG_HOTES=$( { noeuds_role bdd; noeuds_role replique; } | awk '{print $2}' | paste -sd, )

REDEMARRER=0
deposer /etc/resultats/app.env 640 root:resultats <<EOF && REDEMARRER=1
# Fichier engendré par scripts/provision/app.sh — contient un secret
PORT=3000
PG_HOTES=$PG_HOTES
PG_BASE=resultats
PG_UTILISATEUR=resultats_app
PG_MDP_APP=$PG_MDP_APP
MAX_CONNEXIONS=10
EOF
deposer /opt/resultats/resultats.py 755 root:root < /vagrant/app/resultats.py && REDEMARRER=1
if deposer /etc/systemd/system/resultats.service 644 < /vagrant/app/resultats.service; then
  systemctl daemon-reload
  REDEMARRER=1
fi

systemctl enable --quiet resultats
if ! systemctl is-active --quiet resultats; then
  systemctl start resultats
elif [ "$REDEMARRER" = 1 ]; then
  systemctl restart resultats
fi

attendre_http http://127.0.0.1:3000/info 30 || { journalctl -u resultats -n 20 --no-pager; exit 1; }
log "service applicatif prêt : $(curl -s http://127.0.0.1:3000/info) — sonde /sante : $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/sante)"
