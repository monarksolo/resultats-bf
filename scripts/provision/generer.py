#!/usr/bin/env python3
"""Engendre les configurations à partir de la source unique de vérité.

config/noeuds.yml est écrit par le Vagrantfile. Ce script en dérive la
configuration de HAProxy, de keepalived, de Prometheus et le bloc /etc/hosts :
aucune adresse de serveur applicatif n'est écrite en dur nulle part.

Usage : generer.py ip NOM | liste ROLE | vip | reseau | json | hosts | haproxy
                   | keepalived NOM INTERFACE | prometheus
"""
import json
import os
import sys

import yaml

with open(os.environ.get("NOEUDS_YML", "/vagrant/config/noeuds.yml"), encoding="utf-8") as f:
    CONF = yaml.safe_load(f)
NOEUDS = CONF["noeuds"]


def role(r):
    return [n for n in NOEUDS if n["role"] == r]


def noeud(nom):
    for n in NOEUDS:
        if n["nom"] == nom:
            return n
    sys.exit(f"nœud inconnu : {nom}")


def haproxy():
    serveurs = "\n".join(f"    server {n['nom']} {n['ip']}:3000" for n in role("app"))
    promex = "    http-request use-service prometheus-exporter if { path /metrics }\n" \
        if os.environ.get("HAPROXY_PROMEX") == "1" else ""
    return f"""# Fichier ENGENDRÉ depuis config/noeuds.yml — ne pas modifier à la main.
global
    log /dev/log local0 warning
    maxconn 4096
    user haproxy
    group haproxy
    daemon
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    # L'interface graphique est servie depuis la mémoire de HAProxy : elle doit tenir dans un tampon
    tune.bufsize 65536

defaults
    mode http
    log global
    option httplog
    option dontlognull
    option http-server-close
    # Une requête qui échoue sur un serveur mourant est rejouée sur un autre
    retries 3
    retry-on conn-failure empty-response response-timeout
    option redispatch 1
    timeout connect 1s
    timeout client 30s
    timeout server 5s
    timeout check 1500ms
    errorfile 503 /etc/haproxy/errors/503-resultats.http

frontend public
    bind *:80
    # Interface graphique (app/interface.html) et carte de la plateforme : fichiers statiques
    # servis par le répartiteur lui-même, sans solliciter les serveurs applicatifs
    http-request return status 200 content-type "text/html; charset=utf-8" file /etc/haproxy/www/index.html hdr Cache-Control no-cache if {{ path / }}
    http-request return status 200 content-type "application/json" file /etc/haproxy/www/noeuds.json hdr Cache-Control no-cache if {{ path /noeuds.json }}
    # État des serveurs en LECTURE SEULE (CSV : /etat-lb;csv), lu par l'interface
    stats enable
    stats uri /etat-lb
    # Nom du répartiteur qui a traité la requête : rend visible la bascule VRRP
    http-response set-header X-Repartiteur %[hostname]
    default_backend applis

# Sonde de santé (R4) : /sante interroge la base ; 2 échecs à 1 s d'intervalle
# écartent un serveur (pire cas ~4 s), 2 succès le réintègrent.
backend applis
    balance roundrobin
    option httpchk GET /sante
    http-check expect status 200
    default-server check inter 1s fastinter 500ms downinter 2s fall 2 rise 2
{serveurs}

listen statistiques
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 2s
{promex}"""


def keepalived(nom, interface):
    lbs = role("lb")
    moi = noeud(nom)
    pairs = "\n".join(f"        {n['ip']}" for n in lbs if n["nom"] != nom)
    maitre = lbs[0]["nom"] == nom          # lb1 actif, les autres passifs
    priorite = 150 if maitre else 100 - lbs.index(moi)
    return f"""# Fichier ENGENDRÉ depuis config/noeuds.yml — ne pas modifier à la main.
global_defs {{
    router_id {nom}
    enable_script_security
    script_user root
}}

vrrp_script verifier_haproxy {{
    script "/usr/bin/systemctl is-active --quiet haproxy"
    interval 1
    fall 2
    rise 2
}}

vrrp_instance RESULTATS_BF {{
    state {"MASTER" if maitre else "BACKUP"}
    interface {interface}
    virtual_router_id {50 + int(CONF["groupe"])}
    priority {priorite}
    advert_int 1
    unicast_src_ip {moi["ip"]}
    unicast_peer {{
{pairs}
    }}
    authentication {{
        auth_type PASS
        auth_pass {os.environ["VRRP_MDP"][:8]}
    }}
    virtual_ipaddress {{
        {CONF["vip"]}/24 dev {interface}
    }}
    track_script {{
        verifier_haproxy
    }}
}}
"""


def prometheus():
    def cibles(port, noeuds):
        return "\n".join(
            f"      - targets: ['{n['ip']}:{port}']\n        labels: {{noeud: '{n['nom']}', role: '{n['role']}'}}"
            for n in noeuds)
    return f"""# Fichier ENGENDRÉ depuis config/noeuds.yml — ne pas modifier à la main.
global:
  scrape_interval: 5s
  evaluation_interval: 5s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: noeuds
    static_configs:
{cibles(9100, NOEUDS)}

  - job_name: haproxy
    metrics_path: /metrics
    static_configs:
{cibles(8404, role("lb"))}
"""


def main(argv):
    sys.stdout.reconfigure(encoding="utf-8")
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "ip":
        print(noeud(argv[2])["ip"])
    elif cmd == "liste":
        for n in role(argv[2]):
            print(n["nom"], n["ip"])
    elif cmd == "vip":
        print(CONF["vip"])
    elif cmd == "reseau":
        print(CONF["reseau"])
    elif cmd == "json":   # carte de la plateforme lue par l'interface graphique
        print(json.dumps({"groupe": CONF["groupe"], "reseau": CONF["reseau"], "vip": CONF["vip"],
                          "extensions": CONF["extensions"],
                          "noeuds": [{k: n[k] for k in ("nom", "ip", "role")} for n in NOEUDS]},
                         ensure_ascii=False))
    elif cmd == "hosts":
        for n in NOEUDS:
            print(f"{n['ip']}\t{n['nom']}")
    elif cmd == "haproxy":
        sys.stdout.write(haproxy())
    elif cmd == "keepalived":
        sys.stdout.write(keepalived(argv[2], argv[3]))
    elif cmd == "prometheus":
        sys.stdout.write(prometheus())
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
