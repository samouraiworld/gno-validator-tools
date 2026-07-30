# legacy/ — historique, hors périmètre Ansible actif

Ce dossier regroupe ce qui a été retiré du flux Ansible actif lors de la
simplification du dépôt (nginx/TLS/OAuth-proxy hors périmètre, Loki/Prometheus
remplacés par Alloy → VictoriaMetrics en push, déploiement des composes
gnoland devenu manuel). Rien n'est perdu : tout reste consultable ici et dans
l'historique git (`git log --follow -- legacy/...`).

**Ces fichiers ne sont plus maintenus ni garantis fonctionnels tels quels.**
Certains chemins relatifs se sont cassés lors du déplacement (ex: les
playbooks de `legacy/playbooks/` référencent des templates via des chemins
relatifs à leur ancien emplacement à la racine du dépôt, pas à
`legacy/templates/`). Ce sont des références figées, pas du code à rejouer
en l'état.

## Contenu

### `roles/`
- `nginx/` — reverse proxy générique (vhosts par site).
- `nginx-prometheus/` — exporter Prometheus pour NGINX (`:9113`).
- `auth2-proxy/` — OAuth2 Proxy (protection Google OAuth des dashboards).
- `generate_cert_tls/` — automatisation Let's Encrypt (certbot + nginx).

Retirés du périmètre car : plus de reverse proxy ni de TLS géré par Ansible
(choix assumé, voir `NETWORK_AND_REVERSE_PROXY.md` à la racine — mise en
place manuelle si besoin). `nginx-prometheus`, `auth2-proxy` et
`generate_cert_tls` n'étaient déjà plus invoqués par aucun playbook actif
avant ce déplacement.

### `playbooks/`
- `2-install-sentry-node.yml`, `3-install-validator-node.yml` — déploiement
  automatisé (Ansible) du docker-compose sentry/validateur. Remplacés par le
  déploiement manuel décrit dans `DEPLOYMENT_RUNBOOK.md` (les fichiers par
  déploiement — `entrypoint.sh`, `config.toml`, `genesis.json` — changent à
  chaque version de gno et sont poussés à la main, pas templatés par Ansible).
- `5-deploy-monitoring-stack.yaml` — stack Loki + Prometheus + Grafana derrière
  NGINX/Let's Encrypt sur un serveur de monitoring dédié. Dépendait
  entièrement de `roles/nginx` + certbot, donc hors périmètre.
- `5b-deploy-validator-proxies.yaml` — vhosts NGINX sur la sentry pour
  relayer en pull les métriques du validateur vers Prometheus. Obsolète :
  Alloy pousse désormais les métriques en remote_write, plus besoin de
  relais pull par validateur/port.
- `6-deploy-promtail-direct.yaml`, `6-deploy-promtail-sentry.yaml` —
  déploiement de Promtail (direct ou relayé par la sentry). Remplacés par le
  rôle `alloy` (actif, inclus dans `base_setup.yml`), qui couvre à la fois
  les logs Docker et les métriques.

### `templates/`
- `docker-compose.yml.j2`, `docker-sentry.yml.j2`, `docker-validator.yml.j2`,
  `docker-validator-standalone.yml.j2` — templates Jinja2 rendus par les
  playbooks ci-dessus. Remplacés par les composes statiques
  `.env`-configurables de `compose/` à la racine (plus de rendu Ansible).
- `nginx_site.conf.j2`, `nginx_site_otel.conf.j2` — vhosts NGINX génériques,
  déjà orphelins (non référencés par aucun playbook actif) avant ce
  déplacement.

### `Loki/`
Templates du stack monitoring (Loki, Prometheus, Grafana, vhosts NGINX
associés, configs Promtail). Dépendait de `5-deploy-monitoring-stack.yaml`
et `roles/nginx` — voir ci-dessus.

### `group_vars/monitoring.yml.example`
Variables du stack monitoring (`5-deploy-monitoring-stack.yaml`) : versions
Loki/Prometheus/Grafana, domaines, tokens, listes d'IP autorisées, jobs de
scrape Prometheus. Plus aucun playbook actif ne cible un groupe
`monitoring`.

## Ce qui n'est PAS ici

- `validator/backup.sh`, `validator/rotate.sh` et `backup-logs.yaml` restent
  **actifs** à la racine du dépôt : ils fournissent une rétention froide des
  logs indépendante du pipeline Alloy (fenêtre de rétention différente),
  décision explicite de ne pas les déprécier.
- Le rôle `snapshotter` et `install-snapshotter.yml` restent actifs et
  inchangés.
