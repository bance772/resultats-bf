#!/usr/bin/env bash
# =============================================================================
# commun.sh - Provisionnement commun a TOUTES les machines virtuelles.
#   1. Installe les paquets de base (une seule fois).
#   2. Ecrit dans /etc/hosts le nom et l'adresse de chaque machine,
#      a partir de la source unique de verite : /vagrant/config/noeuds.yml
# Idempotent : peut etre rejoue autant de fois que l'on veut (R2).
# =============================================================================
set -euo pipefail                      # arret immediat a la moindre erreur
export DEBIAN_FRONTEND=noninteractive  # apt ne pose aucune question

echo "[commun] $(hostname) : debut du provisionnement commun"

# --- 1. Paquets de base ------------------------------------------------------
# On ne refait 'apt-get update' que si le dernier a plus d'une heure :
# economise la connexion lente (contrainte 7.2). Un fichier "temoin"
# est touche apres chaque mise a jour reussie.
TEMOIN=/var/lib/apt/.resultats-bf-maj
if [ ! -f "$TEMOIN" ] || [ -n "$(find "$TEMOIN" -mmin +60)" ]; then
  apt-get update -q
  touch "$TEMOIN"
fi
# python3-yaml : permet aux scripts de lire noeuds.yml
apt-get install -y -q python3-yaml

# --- 2. /etc/hosts genere depuis noeuds.yml ----------------------------------
# On remplace un bloc delimite par deux marqueurs : rejouer le script
# reecrit le meme bloc au lieu d'ajouter des doublons (piege n°2).
python3 - <<'PYEOF'
import yaml, re

with open("/vagrant/config/noeuds.yml") as f:
    noeuds = yaml.safe_load(f)["noeuds"]

bloc = "# DEBUT resultats-bf (genere, ne pas modifier)\n"
for n in noeuds:
    bloc += f"{n['ip']}\t{n['nom']}\n"
bloc += "# FIN resultats-bf\n"

with open("/etc/hosts") as f:
    contenu = f.read()
contenu = re.sub(r"# DEBUT resultats-bf.*?# FIN resultats-bf\n", "", contenu, flags=re.S)

with open("/etc/hosts", "w") as f:
    f.write(contenu.rstrip("\n") + "\n" + bloc)
PYEOF

echo "[commun] $(hostname) : termine"
