#!/usr/bin/env bash
# =============================================================================
# lb.sh - Provisionnement du repartiteur de charge (HAProxy).
#   1. Installe HAProxy (si absent).
#   2. ENGENDRE la configuration a partir de config/noeuds.yml :
#      aucune adresse de serveur applicatif n'est ecrite en dur (R3).
#   3. Verifie la configuration, puis ne recharge HAProxy QUE si elle a change.
#   4. Extension E1 (si activee) : keepalived et IP virtuelle partagee (VRRP),
#      configuration elle aussi engendree depuis noeuds.yml.
# Idempotent (R2) : rejoue sans changement, il ne modifie rien.
# Execute a chaque 'vagrant up' (run: "always" dans le Vagrantfile).
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

CIBLE=/etc/haproxy/haproxy.cfg
NOUVEAU=$(mktemp)                      # fichier temporaire pour la nouvelle config
KA_CIBLE=/etc/keepalived/keepalived.conf
KA_NOUVEAU=$(mktemp)                   # idem pour keepalived (E1)
trap 'rm -f "$NOUVEAU" "$KA_NOUVEAU"' EXIT   # supprimes a la fin, meme en cas d'erreur

echo "[lb] $(hostname) : debut"

# --- 1. Installation (seulement si HAProxy n'est pas deja installe) ----------
# En cas d'echec (liste des paquets trop ancienne), on la rafraichit et on reessaie.
if ! dpkg -s haproxy >/dev/null 2>&1; then
  apt-get install -y -q haproxy || { apt-get update -q && apt-get install -y -q haproxy; }
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

# --- 4. Extension E1 : keepalived et IP virtuelle ----------------------------
# Le script Python ecrit la configuration keepalived si E1 est activee
# (une IP virtuelle et au moins deux repartiteurs dans noeuds.yml),
# et laisse le fichier VIDE sinon.
python3 - "$KA_NOUVEAU" <<'PYEOF'
import sys, yaml, socket, subprocess

with open("/vagrant/config/noeuds.yml") as f:
    donnees = yaml.safe_load(f)

repartiteurs = [n for n in donnees["noeuds"] if n["role"] == "lb"]
if not donnees.get("vip") or len(repartiteurs) < 2:
    sys.exit(0)                      # E1 desactivee : fichier laisse vide

moi = next(n for n in repartiteurs if n["nom"] == socket.gethostname())
autres = [n for n in repartiteurs if n["nom"] != moi["nom"]]

# Interface reseau qui porte l'adresse privee de cette machine (ex. eth1)
sortie = subprocess.run(["ip", "-o", "-4", "addr", "show"],
                        capture_output=True, text=True, check=True).stdout
interface = next(l.split()[1] for l in sortie.splitlines() if f" {moi['ip']}/" in l)

plus_haute = max(n["priorite"] for n in repartiteurs)
valeurs = {
    "@NOM@":       moi["nom"],
    "@ETAT@":      "MASTER" if moi["priorite"] == plus_haute else "BACKUP",
    "@PRIORITE@":  str(moi["priorite"]),
    "@INTERFACE@": interface,
    "@VRID@":      str(donnees["vrid"]),
    "@IP@":        moi["ip"],
    "@PAIRS@":     "\n".join(f"        {n['ip']}" for n in autres),
    "@VIP@":       donnees["vip"],
}

with open("/vagrant/config/keepalived.conf.tpl") as f:
    contenu = f.read()
for cle, valeur in valeurs.items():
    contenu = contenu.replace(cle, valeur)
if not contenu.endswith("\n"):
    contenu += "\n"

with open(sys.argv[1], "w") as f:
    f.write(contenu)

print(f"[lb] E1 : {moi['nom']} {valeurs['@ETAT@']} (priorite {moi['priorite']}), "
      f"IP virtuelle {donnees['vip']} sur {interface}")
PYEOF

if [ -s "$KA_NOUVEAU" ]; then
  # E1 activee
  if ! dpkg -s keepalived >/dev/null 2>&1; then
    apt-get install -y -q keepalived || { apt-get update -q && apt-get install -y -q keepalived; }
  fi
  keepalived -t -f "$KA_NOUVEAU"        # verification de la syntaxe
  if cmp -s "$KA_NOUVEAU" "$KA_CIBLE"; then
    echo "[lb] keepalived : configuration inchangee"
  else
    install -D -m 644 "$KA_NOUVEAU" "$KA_CIBLE"
    systemctl restart keepalived
    echo "[lb] keepalived : nouvelle configuration appliquee"
  fi
  systemctl enable --quiet keepalived
else
  # E1 desactivee : on s'assure que keepalived ne tourne pas
  if systemctl is-active --quiet keepalived 2>/dev/null; then
    systemctl disable --now keepalived
    echo "[lb] keepalived arrete (E1 desactivee)"
  fi
  echo "[lb] extension E1 desactivee"
fi

echo "[lb] $(hostname) : termine"