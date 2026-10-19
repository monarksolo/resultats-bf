# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# RÉSULTATS-BF — infrastructure entièrement décrite en code.
#
# Source unique de vérité : la table NOEUDS ci-dessous décrit les machines
# virtuelles ET alimente, via config/noeuds.yml, la configuration du
# répartiteur (HAProxy), de keepalived et de Prometheus. Aucune adresse de
# serveur applicatif n'est écrite en dur ailleurs.
#
# Paramètres (variable d'environnement > fichier .env > valeur par défaut) :
#   GROUPE      numéro de groupe          -> sous-réseau 192.168.(56 + (G-1) mod 8).0/24
#               (= 55+G pour les groupes 1 à 8 ; groupe 10 -> 192.168.57.0/24)
#   NB_APP      nombre de serveurs applicatifs (2 à 9)
#   EXTENSIONS  extensions déployées, ex. "E1,E2" (vide = socle seul)

require 'yaml'
require 'fileutils'
require 'securerandom'

RACINE = File.expand_path(__dir__)

# --- Secrets et paramètres : .env (jamais versionné) -------------------------
# À la première exécution, .env est engendré à partir de .env.exemple : chaque
# valeur __GENERE__ (ou __GENERE8__) est remplacée par un secret aléatoire.
# Aucune commande manuelle n'est donc nécessaire après un clonage.
def charger_env(racine)
  chemin  = File.join(racine, ".env")
  exemple = File.join(racine, ".env.exemple")
  unless File.exist?(chemin)
    abort "Fichier .env.exemple introuvable." unless File.exist?(exemple)
    contenu = File.readlines(exemple).map do |ligne|
      next ligne if ligne.lstrip.start_with?("#")   # les commentaires restent intacts
      ligne.gsub("__GENERE8__") { SecureRandom.alphanumeric(8) }
           .gsub("__GENERE__")  { SecureRandom.alphanumeric(24) }
    end.join
    File.write(chemin, contenu)
    puts "==> .env engendré depuis .env.exemple (secrets aléatoires)."
  end
  File.readlines(chemin, chomp: true).each_with_object({}) do |ligne, h|
    next if ligne.strip.empty? || ligne.lstrip.start_with?("#")
    cle, valeur = ligne.split("=", 2)
    h[cle.strip] = valeur.to_s.strip.delete_prefix('"').delete_suffix('"')
  end
end

DOTENV = charger_env(RACINE)
def param(cle, defaut = nil)
  ENV[cle] || DOTENV[cle] || defaut
end

GROUPE     = param("GROUPE", "1").to_i
NB_APP     = param("NB_APP", "2").to_i
EXTENSIONS = param("EXTENSIONS", "").upcase.split(/[\s,;]+/).reject(&:empty?)
BOITE      = "bento/ubuntu-24.04"
VERSION    = param("BOITE_VERSION", "202510.26.0")   # version épinglée, identique pour tous

abort "GROUPE doit être un entier positif (reçu : #{GROUPE})." unless GROUPE >= 1
abort "NB_APP doit être compris entre 2 et 9 (reçu : #{NB_APP})." unless (2..9).cover?(NB_APP)

# VirtualBox (>= 6.1.28) n'autorise par défaut les réseaux hôte-seul que dans
# 192.168.56.0/21, c'est-à-dire 192.168.56.x à 192.168.63.x. La formule du sujet
# (55 + G) en sortirait au-delà du groupe 8 : on la prolonge par
# 56 + (G-1) mod 8, identique à 55 + G pour G = 1..8, et qui reste toujours dans
# la plage autorisée. Aucun poste n'a besoin de modifier /etc/vbox/networks.conf.
RESEAU = "192.168.#{56 + (GROUPE - 1) % 8}"
VIP    = "#{RESEAU}.5"   # adresse IP virtuelle VRRP (extension E1)

# --- Source unique de vérité -------------------------------------------------
NOEUDS = []
NOEUDS << { "nom" => "bdd1", "ip" => "#{RESEAU}.31", "mem" => 768, "role" => "bdd" }
NOEUDS << { "nom" => "bdd2", "ip" => "#{RESEAU}.32", "mem" => 768, "role" => "replique" }
(1..NB_APP).each do |i|
  NOEUDS << { "nom" => "app#{i}", "ip" => "#{RESEAU}.#{20 + i}", "mem" => 512, "role" => "app" }
end
NOEUDS << { "nom" => "lb1", "ip" => "#{RESEAU}.11", "mem" => 512, "role" => "lb", "port_hote" => 8080 }
if EXTENSIONS.include?("E1")
  NOEUDS << { "nom" => "lb2", "ip" => "#{RESEAU}.12", "mem" => 512, "role" => "lb", "port_hote" => 8081 }
end
if EXTENSIONS.include?("E2")
  NOEUDS << { "nom" => "obs", "ip" => "#{RESEAU}.41", "mem" => 768, "role" => "obs" }
end

# Les scripts de provisionnement lisent ce fichier dans /vagrant/config/noeuds.yml
FileUtils.mkdir_p(File.join(RACINE, "config"))
File.write(File.join(RACINE, "config", "noeuds.yml"), {
  "groupe"     => GROUPE,
  "reseau"     => "#{RESEAU}.0/24",
  "vip"        => VIP,
  "extensions" => EXTENSIONS,
  "noeuds"     => NOEUDS
}.to_yaml)

# Script de provisionnement par rôle (la primaire et la réplique partagent bdd.sh)
SCRIPTS = { "bdd" => "bdd.sh", "replique" => "bdd.sh", "app" => "app.sh", "lb" => "lb.sh", "obs" => "obs.sh" }

# Variables transmises aux scripts : les secrets ne quittent jamais .env
ENV_PROVISION = {
  "EXTENSIONS"        => EXTENSIONS.join(","),
  "PG_MDP_APP"        => param("PG_MDP_APP"),
  "PG_MDP_REPLICATION"=> param("PG_MDP_REPLICATION"),
  "VRRP_MDP"          => param("VRRP_MDP"),
  "GRAFANA_MDP_ADMIN" => param("GRAFANA_MDP_ADMIN")
}
manquants = ENV_PROVISION.select { |k, v| v.nil? || v.empty? }.keys - ["EXTENSIONS"]
abort "Variables absentes de .env : #{manquants.join(', ')} (comparez avec .env.exemple)." unless manquants.empty?

Vagrant.configure("2") do |config|
  config.vm.box              = BOITE
  config.vm.box_version      = VERSION
  config.vm.box_check_update = false

  NOEUDS.each do |n|
    config.vm.define n["nom"] do |m|
      m.vm.hostname = n["nom"]
      m.vm.network "private_network", ip: n["ip"]
      # R8 : seul le répartiteur expose un port vers l'hôte
      if n["role"] == "lb"
        m.vm.network "forwarded_port", guest: 80, host: n["port_hote"], host_ip: "127.0.0.1"
      end

      m.vm.provider "virtualbox" do |vb|
        vb.name         = "resultats-bf-g#{GROUPE}-#{n['nom']}"
        vb.memory       = n["mem"]
        vb.cpus         = 1
        vb.linked_clone = true
      end

      # run: "always" : chaque script est idempotent et converge à chaque
      # démarrage ; c'est ce qui permet à « NB_APP=4 vagrant up » de régénérer
      # la configuration du répartiteur déjà en marche.
      m.vm.provision "role", type: "shell",
        path: "scripts/provision/#{SCRIPTS.fetch(n['role'])}",
        args: [n["role"]],
        env: ENV_PROVISION,
        run: "always"
    end
  end
end
