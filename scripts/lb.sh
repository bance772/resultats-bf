#!/usr/bin/env bash
# =============================================================================
# lb.sh - Provisionnement du repartiteur de charge (HAProxy).
#   1. Installe HAProxy (si absent).
#   2. ENGENDRE la configuration a partir de config/noeuds.yml :
#      aucune adresse de serveur applicatif n'est ecrite en dur (R3).
#   3. Verifie la configuration, puis ne recharge HAProxy QUE si elle a change.
# Idempotent (R2) : rejoue sans changement, il ne modifie rien.
# Execute a chaque 'vagrant up' (run: "always" dans le Vagrantfile).
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

CIBLE=/etc/haproxy/haproxy.cfg
NOUVEAU=$(mktemp)                      # fichier temporaire pour la nouvelle config
trap 'rm -f "$NOUVEAU"' EXIT           # supprime a la fin, meme en cas d'erreur

echo "[lb] $(hostname) : debut"

# --- 1. Installation (seulement si HAProxy n'est pas deja installe) ----------
if ! dpkg -s haproxy >/dev/null 2>&1; then
  apt-get install -y -q haproxy
fi

# --- 2. Generation de la configuration depuis la source unique de verite ----
python3 - "$NOUVEAU" <<'PYEOF'
import sys, yaml

with open("/vagrant/config/noeuds.yml") as f:
    donnees = yaml.safe_load(f)

port = donnees["port_app"]
apps = [n for n in donnees["noeuds"] if n["role"] == "app"]

lignes = "\n".join(
    f"    server {n['nom']} {n['ip']}:{port} check" for n in apps
)

with open("/vagrant/config/haproxy.cfg.tpl") as f:
    modele = f.read()

contenu = modele.replace("@SERVEURS@", lignes)
# HAProxy exige que le fichier se termine par un retour a la ligne
if not contenu.endswith("\n"):
    contenu += "\n"

with open(sys.argv[1], "w") as f:
    f.write(contenu)

print(f"[lb] {len(apps)} serveur(s) applicatif(s) : " + ", ".join(n["nom"] for n in apps))
PYEOF

# --- 3. Verification, puis installation seulement si changement --------------
# haproxy -c : controle la syntaxe SANS toucher au service en marche.
haproxy -c -f "$NOUVEAU"

if cmp -s "$NOUVEAU" "$CIBLE"; then
  echo "[lb] configuration inchangee : rien a faire"
else
  install -m 644 "$NOUVEAU" "$CIBLE"
  # reload : les connexions en cours ne sont pas coupees
  systemctl reload-or-restart haproxy
  echo "[lb] nouvelle configuration appliquee"
fi

systemctl enable --quiet haproxy
echo "[lb] $(hostname) : termine"