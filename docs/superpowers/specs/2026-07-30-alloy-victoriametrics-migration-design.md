# Migration node_exporter/promtail → Grafana Alloy + Prometheus → VictoriaMetrics

## Contexte

Aujourd'hui :
- **Métriques** : `node_exporter` (validator + sentry, `:9100`) et `otel-collector` (validator, `:9464`) sont exposés sur `0.0.0.0`. Sur le sentry, `nginx_exporter` (`:9113`) aussi. Le sentry relaie en **pull** les métriques du validator via des vhosts NGINX par validator/par port (`5b-deploy-validator-proxies.yaml`), et Prometheus (sur le monitoring server) scrape tout ça avec une liste statique `prometheus_scrape_jobs` qu'il faut éditer à chaque nouveau nœud.
- **Logs** : `promtail` tourne sur le validator, en mode direct (token en dur, `6-deploy-promtail-direct.yaml`) ou via relais sentry (`6-deploy-promtail-sentry.yaml`, le sentry injecte le bearer token via un vhost `loki-proxy`).

Un prototype fonctionnel existe déjà sur `gno-test14` (devnet topaz, un seul host qui fait tourner les containers docker `topaz-validator-1`, `topaz-sentry-1`, `topaz-tmkms-1`) : Alloy y remplace promtail pour les logs docker (`discovery.docker` + `loki.source.docker` + `loki.write`), et `node_exporter` y a été rebindé en `127.0.0.1:9100` avec Alloy qui le scrape localement et pousse en `remote_write` vers une instance VictoriaMetrics de test (`sentinel.samourai.live`).

## Décisions actées

- **VictoriaMetrics remplace Prometheus** comme backend métriques officiel (remote_write natif, plus d'édition de scrape_jobs à chaque nouveau nœud).
- **node_exporter, otel-collector et nginx_exporter ne sont pas remplacés** : ils restent tels quels dans leur logique de collecte, juste rebindés en `127.0.0.1` (plus jamais exposés au réseau). Alloy devient le seul agent de transport (scrape local + push).
- **Le relais sentry est conservé** pour les deux flux (logs et métriques) : le validator ne détient jamais de bearer token, exactement comme aujourd'hui pour les logs. C'est le sentry qui injecte les tokens vers Loki et VictoriaMetrics.

## Architecture cible

```
Validator ──(VLAN privé, sans token)──► Sentry ──(HTTPS+token)──► Monitoring server
  Alloy:                                  NGINX:                    Docker Compose:
  - scrape local node_exporter/otel       - loki-proxy   (logs)     - Loki
  - remote_write → sentry:vm-proxy        - vm-proxy     (metrics)  - VictoriaMetrics
  - loki.source.docker → sentry:loki-proxy                          - Grafana
                                         Alloy (sentry):
                                         - scrape local node_exporter/nginx_exporter
                                         - remote_write direct → monitoring (token en dur, comme aujourd'hui loki_bearer_token sur promtail-direct)
```

Le mode "direct" (token en dur sur l'agent, sans relais) reste disponible pour les topologies single-host comme gno-test14, au même titre que `6-deploy-promtail-direct.yaml` existe aujourd'hui à côté du mode sentry-relay.

## Phase 1 — VictoriaMetrics sur le monitoring server

**Fichiers modifiés :**
- `Loki/templates/docker-monitoring-stack.yml.j2` : ajoute un service `victoriametrics` (image `victoriametrics/victoria-metrics:v{{ victoriametrics_version }}`), port `127.0.0.1:{{ victoriametrics_http_port | default(8428) }}:8428`, volume `/opt/monitoring/victoriametrics/data`, flag `--retentionPeriod={{ victoriametrics_retention | default('3') }}` (en mois, format natif VM). **Prometheus reste en place** dans cette phase — ajout en parallèle, pas de remplacement, pour rester non-disruptif et testable isolément.
- Nouveau `Loki/templates/nginx-vm-http.conf.j2` (mirroir de `nginx-loki-http.conf.j2`) : vhost sur `{{ victoriametrics_domain }}`, IP allowlist `vm_allowed_ips` (IPs publiques des sentries, mirroir de `loki_allowed_ips`), vérifie `Authorization: Bearer {{ vm_bearer_token }}`, proxy_pass vers `http://127.0.0.1:{{ victoriametrics_http_port }}`.
- Nouveau `Loki/templates/grafana-victoriametrics-datasource.yml.j2` (mirroir de `grafana-loki-datasource.yml.j2`) : `type: prometheus`, `url: http://victoriametrics:{{ victoriametrics_http_port | default(8428) }}` (nom de service docker-compose, résolution DNS interne — VictoriaMetrics expose une API compatible PromQL/Prometheus, donc le datasource Grafana `prometheus` fonctionne tel quel).
- `5-deploy-monitoring-stack.yaml` : nouvelles tasks pour déployer le vhost `vm-http`, la datasource VM, et démarrer le service `victoriametrics` dans le compose. Tag `[stack, config]` cohérent avec l'existant.
- `group_vars/monitoring.yml.example` : ajoute `victoriametrics_version`, `victoriametrics_http_port`, `victoriametrics_retention`, `victoriametrics_domain`, `vm_bearer_token` (générer avec `openssl rand -hex 32`, chiffrer avec ansible-vault — même consigne que `loki_bearer_token`), `vm_allowed_ips`.

**Test :** déployer sur le monitoring server (vagrant ou prod), vérifier `docker compose ps` (victoriametrics up), vérifier que le datasource Grafana répond (vide, aucune série encore poussée), vérifier que `curl -H "Authorization: Bearer wrong"` sur `victoriametrics_domain` renvoie 403.

## Phase 2 — Relais push sur le sentry

**Fichiers modifiés :**
- Nouveau `Loki/templates/nginx-vm-proxy.conf.j2` (mirroir de `nginx-loki-proxy.conf.j2`) : `listen 80` (ou un port dédié — à trancher : soit un vhost supplémentaire sur le port 80 existant du sentry avec un `location /vm/`, soit un port séparé comme le fait `loki-proxy` sur le port 80 avec `location /loki/`). Allowlist `vm_validator_ips` (IPs privées des validators, mirroir de `loki_validator_ips`), injecte `Authorization: Bearer {{ vm_bearer_token }}`, `proxy_pass {{ victoriametrics_scheme | default('https') }}://{{ victoriametrics_domain }}`.
- `group_vars/betanet.yml.example` : `vm_validator_ips` (mirroir de `loki_validator_ips`, définie côté sentry).
- `group_vars/monitoring.yml.example` : le `vm_bearer_token` doit être partagé entre le monitoring server (qui le vérifie) et le sentry (qui l'injecte) — même mécanique que `loki_bearer_token` aujourd'hui.
- **`5b-deploy-validator-proxies.yaml` devient obsolète** — retiré en Phase 4, pas ici (on le laisse tourner en parallèle tant que Prometheus scrape encore en pull, pour ne rien casser avant la bascule complète).
- Ajout d'une nouvelle tâche, probablement dans un `5c-deploy-vm-proxy.yaml` (mirroir de `5b-deploy-validator-proxies.yaml` mais un seul vhost pour tous les validators du sentry, pas un par validator/port) ou intégrée à `5-deploy-monitoring-stack.yaml` — à trancher en phase d'implémentation selon ce qui est le plus lisible.

**Test :** depuis le validator (ou en simulant avec curl depuis le sentry vers lui-même), pousser un payload `remote_write` de test à travers `vm-proxy` et vérifier son arrivée dans VictoriaMetrics via une requête PromQL.

## Phase 3 — Rôle Alloy

**Nouveau rôle `roles/alloy/` :**
- **Installation** : dépôt APT officiel Grafana (clé GPG + `deb [signed-by=...] https://apt.grafana.com stable main`), `apt install alloy`. Le package fournit déjà le service systemd `alloy.service` — pas besoin de le rédiger à la main (contrairement à `node_exporter`/`promtail` aujourd'hui).
- **Configuration** : un seul template `templates/config.alloy.j2`, déployé dans `/etc/alloy/config.alloy`, notifiant un handler `Restart alloy`. Variables (définies par groupe/host dans l'inventaire) :

  | Variable | Rôle | Exemple |
  |---|---|---|
  | `alloy_metrics_targets` | liste de `{job, service, environment, address}` à scraper localement | `node_exporter` toujours, `+otel` sur validator, `+nginx_exporter` sur sentry |
  | `alloy_remote_write_mode` | `direct` (token en dur) ou `relay` (via `vm-proxy` du sentry, VLAN privé) | `relay` pour validator prod, `direct` pour sentry et pour devnet single-host |
  | `alloy_remote_write_url` | URL cible du remote_write | `https://{{ victoriametrics_domain }}/api/v1/write` (direct) ou `http://{{ gno_sentry_private_ip }}/vm/api/v1/write` (relay) |
  | `alloy_logs_enabled` | active ou non la pipeline logs docker | `true` sur validator, `false` sur sentry |
  | `alloy_log_mode` | `direct` ou `relay` (mirroir des playbooks promtail actuels) | idem métriques |
  | `alloy_containers_filter` | regex des containers docker à garder | `topaz-validator-1\|topaz-sentry-1\|topaz-tmkms-1` (reproduit le gno-test14) |
  | `alloy_job_name` | label `job` sur les séries/logs | `{{ moniker_validator }}` |
  | `alloy_bearer_token` | token pour le mode `direct` | `vm_bearer_token` / `loki_bearer_token` selon le flux |

  Le template reproduit fidèlement les 4 blocs déjà validés sur gno-test14 (`discovery.docker`, `discovery.relabel`, `loki.source.docker`, `loki.write`, `prometheus.scrape`, `prometheus.remote_write`), rendus conditionnels/paramétrés via ces variables plutôt qu'en dur.

- **Rebind des exporters existants** (dans ce même chantier, puisque c'est un pré-requis pour qu'Alloy ait un sens) :
  - `roles/node_exporter/files/node_exporter.service` : ajoute `--web.listen-address=127.0.0.1:9100`.
  - `roles/nginx-prometheus/files/nginx_exporter.service` : `--web.listen-address=:9113` → `--web.listen-address=127.0.0.1:9113`.
  - `validator/otel/otel-config.yaml` : exporter prometheus `endpoint: "0.0.0.0:9464"` → `"127.0.0.1:9464"`.
- **`1-base_setup.yml`** : ajoute le rôle `alloy` à la liste des rôles (à côté de `node_exporter`, pas à sa place — `node_exporter` reste responsable du binaire, `alloy` du transport).

**Test :** appliquer le rôle sur un couple validator+sentry vagrant (ou reproduire le devnet single-host comme gno-test14), comparer le `/etc/alloy/config.alloy` généré à la config manuelle déjà validée sur gno-test14 — doit être équivalent à variables près.

## Phase 4 — Bascule et nettoyage

Une fois les phases 1 à 3 validées en production (métriques et logs visibles dans Grafana via VictoriaMetrics/Loki en parallèle de l'ancien pipeline) :

- Arrêt, désactivation et suppression du binaire/service `promtail` sur les validators.
- Suppression de `6-deploy-promtail-direct.yaml` et `6-deploy-promtail-sentry.yaml` (remplacés par les variables du rôle `alloy`).
- Suppression de `5b-deploy-validator-proxies.yaml` (et du `5c-deploy-vm-proxy.yaml` fusionné si applicable) une fois plus aucun scrape en pull ne dépend des vhosts par-validator.
- Suppression du service `prometheus` dans `docker-monitoring-stack.yml.j2` et de `Loki/templates/prometheus-config.yml.j2`.
- Nettoyage de `group_vars/monitoring.yml.example` (retrait de `prometheus_scrape_jobs`, `prometheus_version`, `prometheus_http_port`, `prometheus_retention`) et `group_vars/betanet.yml.example` (retrait des vars promtail devenues inutiles).
- Retrait des règles UFW liées aux ports de scrape pull (`node_exporter_port`, `otel_port` par validator) — plus nécessaires en mode push.
- Mise à jour du diagramme d'architecture et de la table des variables dans `CLAUDE.md`, et du `README.md`.

## Hors périmètre

- La migration effective de `gno-test14` (déjà faite manuellement) — sera simplement ré-appliquée via le rôle une fois prêt, pour vérifier l'idempotence, mais ne bloque pas le reste.
- Le choix du port/chemin exact pour `vm-proxy` sur le sentry (port 80 partagé avec `loki-proxy` vs port dédié) est laissé à la phase d'implémentation — décision de détail sans impact sur l'architecture.
