# Réseau privé & reverse proxy — mise en place manuelle

Ansible ne déploie ni VLAN privé au-delà de l'interface réseau elle-même, ni
reverse proxy, ni TLS. Ce document explique ce qui reste à faire à la main,
et pourquoi ce choix est assumé.

## 1. Réseau privé (VLAN)

Le playbook `setup-private-network.yml` configure uniquement l'interface
réseau (`/etc/network/interfaces` + `ifup`) sur un hôte donné :

```bash
ansible-playbook -i inventory.yaml setup-private-network.yml \
  -e target=gno-sentry -e vlan_id=<vlan_id>

ansible-playbook -i inventory.yaml setup-private-network.yml \
  -e target=gno-validator -e vlan_id=<vlan_id>
```

`vlan_id` est fourni par l'hébergeur (ex: Scaleway Private Networks). Lancer
ce playbook **après** avoir validé que les nœuds tournent correctement en
IP publique — activer le VLAN en cours de déploiement peut couper l'accès
SSH si mal configuré.

Une fois le VLAN actif, le validateur peut couper son accès Internet public
tout en gardant le VLAN privé opérationnel — voir `validator/Network_control.md`
(copié manuellement sur le validateur, cf. `DEPLOYMENT_RUNBOOK.md`) :

```bash
ssh root@<validator-ip>
ip addr flush dev eno1      # coupe Internet, garde le VLAN
dhclient eno1                # réactive Internet (utile pour rejouer un playbook)
```

## 2. Pourquoi pas de reverse proxy / TLS via Ansible

Les rôles `nginx`, `nginx-prometheus`, `auth2-proxy` et `generate_cert_tls`
ont été retirés du périmètre actif (déplacés en historique dans `legacy/`,
voir `legacy/README.md`). Ce n'est pas un oubli : c'est un choix délibéré
pour garder ce dépôt concentré sur le strict socle serveur (`base_setup.yml`)
et le déploiement applicatif (`compose/`). Conséquence assumée : **pas de
renouvellement Let's Encrypt automatisé pour l'instant**.

Si un reverse proxy est nécessaire (typiquement sur la sentry, en frontal
public), il est installé et maintenu à la main par l'opérateur — nginx,
Caddy ou autre, au choix. Cas d'usage concrets :

- **Exposer un dashboard ou une API HTTPS** devant la sentry.
- **Relayer le push d'Alloy** si le validateur est isolé sur le VLAN privé
  sans sortie Internet directe : le rôle `alloy` supporte déjà nativement
  ce mode relais (`alloy_log_mode` / `alloy_remote_write_mode: "relay"`,
  voir `roles/alloy/templates/config.alloy.j2` et les exemples commentés
  dans `inventory.yaml.example`). Dans ce mode, Alloy sur le validateur
  pousse vers une URL interne (ex: `http://<sentry_private_ip>/vm/...` ou
  `.../loki/...`) ; c'est ce reverse proxy monté à la main sur la sentry qui
  relaie ensuite vers la vraie destination (VictoriaMetrics / backend de
  logs), en y ajoutant si besoin un token porté uniquement par la sentry —
  le validateur ne détient jamais ce secret.
- En mode `"direct"`, Alloy pousse directement vers l'URL finale avec son
  propre token (`alloy_bearer_token`) — pas de reverse proxy nécessaire côté
  validateur, mais celui-ci doit alors avoir une sortie Internet directe.

Aucun de ces deux modes ne nécessite de modification du rôle `alloy` : ils
sont déjà pilotables entièrement par variables d'inventaire.

## 3. Firewall (UFW)

Le rôle `ufw` (inclus dans `base_setup.yml`) ouvre uniquement :
- le port SSH (22),
- les ports applicatifs déclarés dans `ufw_ports_app` (typiquement `26656`
  pour le P2P gnoland),
- optionnellement, des ports restreints à une IP unique via `ufw_ports_moni`
  + `ufw_allow_ip` — mécanisme générique gardé disponible mais **vide par
  défaut**, puisque plus aucun port de métriques (node_exporter, otel,
  nginx_exporter) n'a besoin d'être exposé en écoute publique depuis le
  passage au modèle push (Alloy → remote_write). node_exporter et l'export
  Prometheus d'otel-collector restent bindés en `127.0.0.1`.

Si un reverse proxy manuel est mis en place devant un service, c'est à
l'opérateur d'ouvrir le port correspondant (`ufw allow <port>` à la main, ou
via `ufw_ports_app`/`ufw_ports_moni` selon le besoin).
