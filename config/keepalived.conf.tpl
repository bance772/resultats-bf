# =============================================================================
# /etc/keepalived/keepalived.conf - FICHIER GENERE AUTOMATIQUEMENT par lb.sh
#   Modele : config/keepalived.conf.tpl
#   Source : config/noeuds.yml (source unique de verite)
# Extension E1 : deux repartiteurs se partagent une IP virtuelle (VRRP).
# Ne pas modifier a la main.
# =============================================================================

global_defs {
    router_id @NOM@
    enable_script_security
    script_user root
}

# Sonde locale : cette machine n'est candidate a l'IP virtuelle que si
# HAProxy tourne. Si HAProxy s'arrete, l'IP part sur l'autre repartiteur.
vrrp_script verifier_haproxy {
    script "/usr/bin/systemctl is-active --quiet haproxy"
    interval 1
    fall 2
    rise 2
}

vrrp_instance VI_RESULTATS {
    # Le repartiteur de plus forte priorite porte l'IP virtuelle
    state @ETAT@
    priority @PRIORITE@
    interface @INTERFACE@
    virtual_router_id @VRID@
    # Annonce "je suis vivant" toutes les secondes ; sans annonce pendant
    # environ 3 s, l'autre repartiteur prend l'IP virtuelle (< 5 s exiges)
    advert_int 1

    # Annonces envoyees directement a l'autre repartiteur (unicast) :
    # plus fiable que la multidiffusion sur un reseau VirtualBox
    unicast_src_ip @IP@
    unicast_peer {
@PAIRS@
    }

    virtual_ipaddress {
        @VIP@/24 dev @INTERFACE@
    }

    track_script {
        verifier_haproxy
    }
}