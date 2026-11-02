# RÉSULTATS-BF — Guide du Rôle Données & Réplication

> **Projet :** RÉSULTATS-BF — Infrastructure résiliente et scalable sous Vagrant  
> **Module :** DevOps et infrastructures reproductibles (2026-2027) — Dr Flavien Hervé SOMDA  
> **Groupe :** Groupe 7  
> **Responsable du composant Données :** Hawa PANANDETIGUI  

---

## 1. Vue d'ensemble du périmètre Données

Le rôle **Ingénieur données** a la responsabilité de garantir la haute disponibilité, l'intégrité et la persistance des résultats d'examen (50 000 candidats burkinabè). Ce périmètre comprend :

1. La base primaire **`bdd1`** (`192.168.62.31`) hébergeant les données d'origine.
2. La réplique en flux **`bdd2`** (`192.168.62.32`) assurant la redondance continue en mode Standby.
3. La procédure de bascule (**Failover**) en cas de défaillance de la primaire (Scénario V4).

---

## 2. État actuel & Ce qui a déjà été préparé sur `bdd1`

Grâce aux travaux déjà initialisés dans [`scripts/bdd.sh`](../scripts/bdd.sh), la machine primaire **`bdd1`** est **déjà 100 % configurée** pour la réplication :

- **PostgreSQL 16** écoute sur `0.0.0.0:5432`.
- Les 50 000 enregistrements déterministes sont insérés dans la base `resultats`.
- **Paramètres de réplication activés dans `postgresql.auto.conf` :**
  ```sql
  wal_level = 'replica'
  max_wal_senders = 5
  wal_keep_size = '64'
  ```
- **Rôle de réplication dédié créé :**
  ```sql
  CREATE ROLE "replicateur" REPLICATION LOGIN PASSWORD '${REPLIC_MOT_DE_PASSE}';
  ```
- **Sécurité réseau dans `pg_hba.conf` :**  
  L'adresse IP de `bdd2` (`192.168.62.32/32`) est explicitement autorisée avec la méthode d'authentification `scram-sha-256`.

---

## 3. Ce qu'il reste à faire : `scripts/replique.sh`

Le fichier [`scripts/replique.sh`](../scripts/replique.sh) doit automatiser l'installation et le clonage initial de **`bdd2`**.

### 3.1. Code complet attendu pour `scripts/replique.sh`

Voici le script idempotent (règle R2) prêt à être intégré dans `scripts/replique.sh` :

```bash
#!/usr/bin/env bash
# =============================================================================
# replique.sh — Provisionnement de bdd2 (PostgreSQL réplique en flux)
#   1. Installe PostgreSQL 16 (si absent).
#   2. Si bdd2 n'est pas encore initialisée en réplique :
#      - Arrête le service local.
#      - Purge le répertoire cluster par défaut (/var/lib/postgresql/16/main).
#      - Exécute pg_basebackup depuis bdd1 avec l'option -R (crée standby.signal).
#      - Rétablit les permissions postgres:postgres.
#      - Démarre le service en mode réplique.
# Idempotent (R2) : rejoué deux fois, ne détruit pas une réplication déjà active.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PGVER=16
PGDATA="/var/lib/postgresql/${PGVER}/main"

echo "[replique] $(hostname) : début du provisionnement"

# 1. Installation de PostgreSQL 16 (si non installé)
if ! dpkg -s "postgresql-${PGVER}" >/dev/null 2>&1; then
  apt-get install -y -q "postgresql-${PGVER}"
fi

# 2. Initialisation du clonage uniquement si non déjà configuré en réplique
if [ ! -f "${PGDATA}/standby.signal" ]; then
  echo "[replique] Arrêt du cluster local par défaut..."
  systemctl stop postgresql

  echo "[replique] Nettoyage des données par défaut..."
  rm -rf "${PGDATA:?}"/*

  echo "[replique] Clonage en flux depuis bdd1 via pg_basebackup..."
  PGPASSWORD="${REPLIC_MOT_DE_PASSE}" pg_basebackup \
    -h bdd1 \
    -p 5432 \
    -U "${REPLIC_UTILISATEUR}" \
    -D "${PGDATA}" \
    -Fp -Xs -R

  echo "[replique] Rétablissement des permissions sur PGDATA..."
  chown -R postgres:postgres "${PGDATA}"
  chmod 700 "${PGDATA}"

  echo "[replique] Démarrage de la réplique PostgreSQL..."
  systemctl start postgresql
else
  echo "[replique] Réplication déjà en place (standby.signal présent)."
  systemctl start postgresql
fi

systemctl enable --quiet postgresql
echo "[replique] $(hostname) : réplique opérationnelle"
```

---

## 4. Guide d'exécution et de validation

### 4.1. Démarrer la réplique
Depuis PowerShell sur l'hôte :

```powershell
vagrant up bdd2
```

---

### 4.2. Commandes de vérification de la réplication

#### Test 1 : Contrôle du flux depuis `bdd1`
Vérifier que `bdd1` a bien un processus émetteur (*walsender*) vers `bdd2` :

```powershell
vagrant ssh bdd1 -c "sudo -u postgres psql -x -c 'SELECT client_addr, state, sync_state, replay_lsn FROM pg_stat_replication;'"
```
**Résultat attendu :**
- `client_addr` : `192.168.62.32`
- `state` : `streaming`

#### Test 2 : Contrôle de l'état Standby sur `bdd2`
Vérifier que `bdd2` est bien en mode récupération continue (lecture seule) :

```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'"
```
**Résultat attendu :**
```text
 pg_is_in_recovery 
-------------------
 t
(1 row)
```
*(Le `t` signifie True).*

#### Test 3 : Vérification de la présence des 50 000 lignes sur `bdd2`
```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -c 'SELECT count(*) FROM resultats;'"
```
**Résultat attendu :** `50000`.

---

## 5. Procédure de Bascule (Failover — Scénario V4)

Le scénario V4 de Brigitte consiste à simuler la perte brutale de la primaire `bdd1` et à vérifier que le service reste disponible.

### Étape 1 : Simulation du crash de `bdd1`
```powershell
vagrant halt bdd1
```

### Étape 2 : Promotion de `bdd2` en nouvelle primaire
Depuis `bdd2`, exécuter la fonction SQL de promotion :

```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -c 'SELECT pg_promote();'"
```
PostgreSQL supprime alors `standby.signal` et passe immédiatement en lecture-écriture.

### Étape 3 : Constat côté applicatif
Le service Flask configuré par Soumana DAMA utilise la chaîne :
`host=bdd1,bdd2 target_session_attrs=read-write`

L'application détecte automatiquement que `bdd1` ne répond plus et bascule ses écritures/lectures sur `bdd2` sans aucune modification de code ni redémarrage de VM !

---

## 6. Récapitulatif des règles à respecter

- **R1 (Reproductibilité) :** La destruction (`vagrant destroy -f bdd2`) puis recréation (`vagrant up bdd2`) doit réinitialiser la réplique sans accroc.
- **R2 (Idempotence) :** Le test `if [ ! -f "${PGDATA}/standby.signal" ]` évite d'écraser la base si le script est rejoué.
- **R6 (Secrets) :** Les mots de passe sont reçus par variables d'environnement (`REPLIC_MOT_DE_PASSE`), jamais écrits en dur.
