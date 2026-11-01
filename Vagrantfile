# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# RESULTATS-BF - Infrastructure entierement decrite en code.
# Une seule commande reconstruit toute la plateforme :  vagrant up
#
require 'yaml'
require 'fileutils'

# ---------------------------------------------------------------------------
# 1. Lecture du fichier .env (secrets et parametres, jamais versionne - R7)
# ---------------------------------------------------------------------------
def lire_env(chemin)
  unless File.exist?(chemin)
    abort "ERREUR : fichier .env introuvable.\n" \
          "Creez-le a partir du modele :  copy .env.exemple .env  (voir README)"
  end
  valeurs = {}
  File.readlines(chemin, chomp: true).each do |ligne|
    ligne = ligne.strip
    next if ligne.empty? || ligne.start_with?('#')   # ignore vides et commentaires
    cle, valeur = ligne.split('=', 2)
    valeurs[cle.strip] = valeur.to_s.strip
  end
  valeurs
end

DOTENV = lire_env(File.join(__dir__, '.env'))

# Priorite : variable d'environnement > fichier .env > valeur par defaut
def parametre(nom, defaut)
  ENV[nom] || DOTENV[nom] || defaut
end

# ---------------------------------------------------------------------------
# 2. Parametres de l'infrastructure
# ---------------------------------------------------------------------------
GROUPE = parametre('GROUPE', '1').to_i      # numero de groupe, 1 a 8
NB_APP = parametre('NB_APP', '2').to_i      # nombre de serveurs applicatifs (R3)
AVEC_LB2 = parametre('AVEC_LB2', '0') == '1' # extension E1 : repartiteur redondant

abort "ERREUR : GROUPE doit valoir entre 1 et 8 (recu : #{GROUPE})" unless (1..8).include?(GROUPE)
abort "ERREUR : NB_APP doit valoir entre 2 et 9 (recu : #{NB_APP})" unless (2..9).include?(NB_APP)

RESEAU  = "192.168.#{55 + GROUPE}"         # plage imposee par VirtualBox (7.1)
PORT_APP = 8000                             # port d'ecoute des serveurs applicatifs
VIP      = "#{RESEAU}.10"                   # IP virtuelle partagee par lb1/lb2 (E1)
VRID     = 50 + GROUPE                      # identifiant VRRP, distinct par groupe
BOITE   = "bento/ubuntu-24.04"
VERSION = "202510.26.0"                     # version epinglee, identique pour tous

# Secrets transmis aux scripts de provisionnement (jamais ecrits dans le depot)
SECRETS = {
  "DB_NOM"              => parametre('DB_NOM', 'resultats'),
  "DB_UTILISATEUR"      => parametre('DB_UTILISATEUR', 'app_resultats'),
  "DB_MOT_DE_PASSE"     => parametre('DB_MOT_DE_PASSE', ''),
  "REPLIC_UTILISATEUR"  => parametre('REPLIC_UTILISATEUR', 'replicateur'),
  "REPLIC_MOT_DE_PASSE" => parametre('REPLIC_MOT_DE_PASSE', ''),
}
SECRETS.each do |cle, valeur|
  abort "ERREUR : #{cle} est vide dans .env" if valeur.empty? || valeur == 'a_remplacer'
end

# ---------------------------------------------------------------------------
# 3. SOURCE UNIQUE DE VERITE (R3)
#    Cette table decrit les VM ET alimente la configuration du repartiteur.
#    L'ordre compte : la base demarre avant les serveurs applicatifs.
# ---------------------------------------------------------------------------
NOEUDS = []
NOEUDS << { "nom" => "bdd1", "ip" => "#{RESEAU}.31", "mem" => 768, "role" => "bdd" }
NOEUDS << { "nom" => "bdd2", "ip" => "#{RESEAU}.32", "mem" => 768, "role" => "replique" }
(1..NB_APP).each do |i|
  NOEUDS << { "nom" => "app#{i}", "ip" => "#{RESEAU}.#{20 + i}", "mem" => 512, "role" => "app" }
end
# Repartiteurs : lb1 est prioritaire (maitre) ; lb2 n'existe qu'avec l'extension E1
NOEUDS << { "nom" => "lb1", "ip" => "#{RESEAU}.11", "mem" => 512, "role" => "lb", "priorite" => 150 }
if AVEC_LB2
  NOEUDS << { "nom" => "lb2", "ip" => "#{RESEAU}.12", "mem" => 512, "role" => "lb", "priorite" => 100 }
end

# Les scripts lisent ce fichier dans la VM : /vagrant/config/noeuds.yml
FileUtils.mkdir_p(File.join(__dir__, "config"))
File.write(File.join(__dir__, "config", "noeuds.yml"),
           { "reseau" => RESEAU, "port_app" => PORT_APP,
             "vip" => (AVEC_LB2 ? VIP : nil), "vrid" => VRID,
             "noeuds" => NOEUDS }.to_yaml)

# ---------------------------------------------------------------------------
# 4. Description des machines virtuelles
# ---------------------------------------------------------------------------
Vagrant.configure("2") do |config|
  config.vm.box              = BOITE
  config.vm.box_version      = VERSION
  config.vm.box_check_update = false

  NOEUDS.each do |n|
    config.vm.define n["nom"] do |m|
      m.vm.hostname = n["nom"]

      # Reseau prive hote-seul : tout le trafic interne passe ici (R8)
      m.vm.network "private_network", ip: n["ip"]

      # Seul le repartiteur lb1 expose un port vers l'hote (R8).
      # Avec E1, on utilise plutot l'IP virtuelle : http://VIP (voir README)
      if n["nom"] == "lb1"
        m.vm.network "forwarded_port", guest: 80, host: 8080, host_ip: "127.0.0.1"
      end

      m.vm.provider "virtualbox" do |vb|
        vb.name         = "resultats-bf-g#{GROUPE}-#{n['nom']}"
        vb.memory       = n["mem"]
        vb.cpus         = 1
        vb.linked_clone = true    # clone lie : creation rapide, peu d'espace disque
      end

      # Provisionnement : d'abord le commun, puis le script du role.
      # Le repartiteur est reprovisionne a CHAQUE 'vagrant up' (run: "always") :
      # sa configuration suit donc automatiquement NB_APP (R3).
      # Possible sans risque car lb.sh est idempotent (R2).
      m.vm.provision "commun", type: "shell", path: "scripts/commun.sh"
      m.vm.provision n["role"], type: "shell", path: "scripts/#{n['role']}.sh",
                     env: (n["role"] == "lb" ? {} : SECRETS),
                     run: (n["role"] == "lb" ? "always" : "once")
    end
  end
end