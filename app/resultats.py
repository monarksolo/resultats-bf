#!/usr/bin/env python3
"""RÉSULTATS-BF — service SANS ÉTAT (tout l'état vit dans PostgreSQL).
GET /resultat?matricule=... (JSON lu en base) · GET /sante (200 si la base répond, 503 sinon) · GET /info"""
import json, os, queue, socket, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import psycopg2

VERSION = "1.0.0"
HOTE = socket.gethostname()

# Plusieurs hôtes + target_session_attrs : libpq choisit seul la base qui accepte
# les écritures ; après une bascule, rien à reconfigurer. Aucune connexion n'est
# ouverte au démarrage : le service démarre même sans base et réessaie à chaque
# requête. Le pool n'est qu'un cache de connexions, pas un état applicatif.
PARAMS = dict(
    host=os.environ["PG_HOTES"], port=os.environ.get("PG_PORTS", "5432"),
    dbname=os.environ.get("PG_BASE", "resultats"), user=os.environ.get("PG_UTILISATEUR", "resultats_app"),
    password=os.environ["PG_MDP_APP"], target_session_attrs="read-write", connect_timeout=2,
    keepalives=1, keepalives_idle=5, keepalives_interval=2, keepalives_count=2,
    tcp_user_timeout=4000, options="-c statement_timeout=2000", application_name=f"resultats-{HOTE}")
_libres = queue.LifoQueue()                      # connexions ouvertes et inactives
_places = threading.BoundedSemaphore(int(os.environ.get("MAX_CONNEXIONS", "10")))


def vider_pool():
    while True:
        try:
            _libres.get_nowait().close()
        except queue.Empty:
            return


def requete(sql, args=()):
    """Après une erreur (ex. bascule), les connexions inactives sont jetées et l'on réessaie une fois."""
    for tentative in (1, 2):
        with _places:
            try:
                conn = _libres.get_nowait()
            except queue.Empty:
                conn = psycopg2.connect(**PARAMS)
            try:
                with conn.cursor() as cur:
                    cur.execute(sql, args)
                    ligne = cur.fetchone()
                conn.rollback()
                _libres.put(conn)
                return ligne
            except psycopg2.Error:
                conn.close()
                vider_pool()
                if tentative == 2:
                    raise


class Gestionnaire(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def repondre(self, code, corps):
        donnees = json.dumps(corps, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(donnees)))
        self.send_header("X-Serveur", HOTE)
        self.send_header("Connection", "close")
        try:
            self.end_headers()
            self.wfile.write(donnees)
        except ConnectionError:   # les sondes HAProxy coupent (RST) dès le code lu : rien à journaliser
            pass

    def do_GET(self):
        url = urlparse(self.path)
        try:
            if url.path == "/info":
                return self.repondre(200, {"serveur": HOTE, "version": VERSION})
            if url.path == "/sante":
                base = requete("SELECT host(inet_server_addr())")[0]   # jamais 200 « par principe »
                return self.repondre(200, {"statut": "ok", "serveur": HOTE, "base": base})
            if url.path == "/resultat":
                matricule = parse_qs(url.query).get("matricule", [""])[0].strip().upper()
                sql = "SELECT matricule, nom, serie, moyenne, admis FROM resultats WHERE matricule = %s"
                l = matricule and requete(sql, (matricule,))
                if not l:
                    return self.repondre(404, {"erreur": "matricule inconnu ou absent", "matricule": matricule})
                return self.repondre(200, dict(matricule=l[0], nom=l[1], serie=l[2], moyenne=float(l[3]), admis=l[4]))
            return self.repondre(404, {"erreur": "point d'entrée inconnu"})
        except psycopg2.Error:
            return self.repondre(503, {"erreur": "base de données indisponible", "serveur": HOTE})

    def log_message(self, *args):   # pas de journal par requête : trop coûteux en CPU sous charge
        pass


if __name__ == "__main__":
    serveur = ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "3000"))), Gestionnaire)
    print(f"RÉSULTATS-BF {VERSION} sur {HOTE}:{serveur.server_address[1]}", flush=True)
    serveur.serve_forever()
