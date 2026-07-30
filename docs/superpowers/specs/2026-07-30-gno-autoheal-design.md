# Design — Auto-heal : détection de blocage + restore automatique (sentry & validator)

Statut : **design validé par l'utilisateur, non implémenté**. Ce document sert
de base au plan d'implémentation détaillé (prochaine étape).

## 1. Contexte

Le rôle `roles/snapshotter` existe déjà et est fonctionnel :

- un nœud non-signant dédié (`snapshotter`) suit la chaîne en P2P sur l'hôte
  du sentry ;
- `snapshot.sh` (timer systemd horaire) l'arrête, `tar`+`zstd` son `db`
  (`wal` exclu), le redémarre, fait tourner la rotation locale ;
- `push-to-s3.sh` envoie les archives vers un bucket Scaleway Object Storage
  (S3-compatible) via `rclone`, et purge le distant pour ne garder que les
  `KEEP_LAST` snapshots les plus récents (par hauteur de bloc) ;
- `restore.sh` restaure `gnoland-data/{db,wal}` d'un nœud (`snapshotter`,
  `sentry` ou `validator`) depuis une archive locale, avec confirmation
  interactive obligatoire pour le validateur (garde-fou anti-double-sign).

Ce pipeline est **manuel** : quelqu'un doit remarquer qu'un nœud est bloqué,
aller chercher l'archive sur Scaleway, puis lancer `restore.sh` à la main.

Ce design ajoute la couche manquante : **détection automatique d'un nœud
bloqué + restore automatique de bout en bout**, sur le sentry ET le
validateur.

## 2. Objectif

Quand un nœud (sentry ou validateur) cesse de progresser (hauteur figée,
`catching_up=false`), le système doit, sans intervention humaine :

1. le détecter de façon fiable (pas de faux positif sur un simple ralenti
   réseau) ;
2. sauvegarder l'état incident local avant d'y toucher ;
3. récupérer le dernier snapshot disponible sur Scaleway ;
4. restaurer et redémarrer le nœud ;
5. vérifier que le redémarrage a réellement résolu le blocage ;
6. alerter à chaque étape clé (déclenchement, succès, échec).

## 3. Hors périmètre

- Construction du pipeline de capture/upload (déjà fait, `roles/snapshotter`).
- Bootstrap d'un nœud neuf depuis zéro (couvert par `restore.sh` existant,
  utilisable manuellement — pas de changement ici).
- Mécanisme de lock distant / heartbeat inter-hosts (écarté : la vérification
  locale des containers suffit, cf. §6).
- Alerting riche (dashboard, escalade) — un webhook HTTP générique suffit en
  v1.

## 4. Architecture

```
systemd timer (gno-autoheal-check.timer, cadence configurable)
        │
        ▼
check-stuck.sh <sentry|validator>          (lecture RPC locale, AUCUN effet de bord)
        │  état persistant : /var/lib/gno-autoheal/<node>.state
        │  (dernière hauteur vue, timestamp, compteur d'échantillons sans progression)
        │
        ▼ si bloqué N fois de suite consécutives ET catching_up=false
autoheal.sh <sentry|validator>             (orchestrateur, EFFETS DE BORD)
        │  lock file : /var/lib/gno-autoheal/<node>.lock (+ cooldown anti-flapping)
        │
        ├─ 1. alerte webhook "restore déclenché"
        ├─ 2. backup incident local (tar horodaté COMPLET de gnoland-data,
        │     y compris secrets — hors snapshot, pour forensic uniquement)
        ├─ 3. pull-from-s3.sh <chain_id>  → dernier snapshot Scaleway en local
        ├─ 4. si validator : vérif locale gnoland+tmkms bien "exited"
        │     (docker compose ps) avant tout wipe
        ├─ 5. restore.sh <deploy_dir> <archive> <service> --yes
        ├─ 6. restart dans l'ordre correct (gnoland puis tmkms si validator)
        └─ 7. poll RPC jusqu'à catching_up=false ou timeout
              → alerte succès / échec final
```

## 5. Composants

`roles/snapshotter` ne se déploie **que sur l'hôte sentry** (capture + push,
périmètre inchangé). L'autoheal doit couvrir sentry ET validateur → nouveau
rôle dédié, appliqué sur les deux groupes d'inventaire.

| Fichier | Rôle | Statut |
|---|---|---|
| `roles/autoheal/files/check-stuck.sh` | Détection pure, lecture seule | Nouveau |
| `roles/autoheal/files/pull-from-s3.sh` | Miroir de `push-to-s3.sh` (lecture seule) : liste le distant, prend le plus haut (par hauteur), télécharge en local | Nouveau |
| `roles/autoheal/files/autoheal.sh` | Orchestrateur (appelle `pull-from-s3.sh` + `restore.sh`, ne duplique pas leur logique) | Nouveau |
| `roles/autoheal/files/restore.sh` | Copie dédiée (déploiement sur un hôte que `roles/snapshotter` ne touche pas), flag `--yes` dès le départ ; le garde-fou devient la vérif automatique de l'étape 4. `roles/snapshotter/files/restore.sh` n'est pas touché (reste tel quel pour l'usage manuel existant sur l'hôte sentry) | Nouveau |
| `roles/autoheal/templates/gno-autoheal-check.service.j2` + `.timer.j2` | Déclenchement périodique de `check-stuck.sh` | Nouveau |
| `roles/autoheal/defaults/main.yml` | Variables (node_type, service compose, cadence, seuil N, timeout webhook, cooldown) | Nouveau |
| `roles/autoheal/templates/autoheal.env.example.j2` | `WEBHOOK_URL`, `SCW_ACCESS_KEY`/`SCW_SECRET_KEY` (clé Scaleway **lecture seule** recommandée côté validateur), `S3_BUCKET`/`S3_ENDPOINT`/`S3_REGION` | Nouveau |
| `roles/autoheal/README.md` | Documentation du rôle | Nouveau |
| `install-autoheal.yml` | Playbook, cible `sentries` + `validators` | Nouveau |
| `roles/snapshotter/README.md` | Correction de la mention lifecycle Scaleway (obsolète depuis le correctif `KEEP_LAST`, cf. conversation précédente) | Modifié |

Détection sentry ET validateur avec le **même** `check-stuck.sh`/`autoheal.sh`,
paramétrés par une variable `node_type` (sentry|validator) — pas deux scripts
séparés — pour éviter la duplication ; les branches spécifiques au validateur
(étape 4, ordre de redémarrage) sont des `if` internes.

Chaque hôte pull son propre snapshot depuis Scaleway (pas de dépendance au
snapshot local du sentry, même s'il est co-localisé avec le snapshotter) :
code uniforme entre les deux node_type, un seul chemin à tester.

## 6. Détection (`check-stuck.sh`)

- Lit `$RPC/status` en local (le validateur et le sentry exposent chacun leur
  RPC en localhost, comme le snapshotter).
- Compare à l'état précédent stocké dans `/var/lib/gno-autoheal/<node>.state`
  (JSON simple : `height`, `ts`, `stuck_count`).
- Si `latest_block_height` n'a pas progressé depuis le dernier run **et**
  `catching_up=false` → incrémente `stuck_count`. Sinon, le remet à 0.
- Déclenche `autoheal.sh <node>` seulement quand `stuck_count >= STUCK_THRESHOLD`
  (défaut 3 — avec un timer toutes les 3 min, ça fait ~9 min de blocage confirmé
  avant action, pour absorber les faux positifs).
- Si le RPC est injoignable (nœud down plutôt que bloqué), c'est un cas
  différent : logué mais **ne déclenche pas** l'autoheal en v1 (un nœud down
  a besoin d'investigation, pas forcément d'un restore — un restore ne
  résout pas un docker qui ne démarre pas).

## 7. Garde-fou anti-double-sign (validateur)

Conforme à la décision validée précédemment : **vérification locale
uniquement**, pas de lock distant. Avant tout wipe du validateur,
`autoheal.sh` :

1. `docker compose stop validator tmkms` (idempotent, pas d'erreur si déjà
   stoppés) ;
2. vérifie via `docker compose ps` que les deux containers sont bien à l'état
   `exited` — sinon, abandonne et alerte en critique (ne jamais wiper avec un
   signataire encore potentiellement actif) ;
3. seulement alors, restaure `db`/`wal` (jamais les secrets/tmkms — inchangé
   par rapport à `restore.sh` existant) ;
4. redémarre `gnoland` (le listener tmkms) **avant** `tmkms` (le sidecar se
   connecte au listener, pas l'inverse).

Le flag `--yes` de `restore.sh` ne supprime pas le garde-fou : il transfère la
responsabilité de la confirmation humaine vers cette vérification
programmatique.

## 8. Anti-flapping

`autoheal.sh` pose un lock file avec cooldown
(`/var/lib/gno-autoheal/<node>.lock`, défaut 30 min) : si un restore vient de
tourner, un nouveau déclenchement dans la fenêtre de cooldown est bloqué et
alerte en critique immédiatement (signal qu'un restore n'a pas résolu le
problème — besoin d'investigation humaine, pas d'une boucle de restores).

## 9. Alerting

Webhook HTTP générique (`WEBHOOK_URL` dans `.env`, POST JSON), déclenché à :
blocage détecté (avant action), succès du restore, échec du restore, restore
bloqué par le garde-fou ou le cooldown. Format du payload libre en v1 (juste
`{node, event, height, message, timestamp}`) — compatible Slack/Discord/autre
via un relai côté opérateur si besoin.

## 10. Vérification post-restore

Après redémarrage, `autoheal.sh` poll `$RPC/status` jusqu'à
`catching_up=false` ou un timeout (défaut 20 min, configurable — le temps de
rattraper le delta depuis la hauteur du snapshot dépend de l'ancienneté du
snapshot). Sur timeout, alerte critique — pas de nouvelle tentative
automatique (couvert par le cooldown, §8).

## 11. Erreurs / cas limites

- Aucun snapshot disponible sur Scaleway (bucket vide/inaccessible) →
  `pull-from-s3.sh` échoue, `autoheal.sh` alerte critique et s'arrête avant
  tout wipe (le nœud actuel n'est jamais touché si le remplacement n'est pas
  disponible).
- Snapshot plus vieux que l'état actuel du nœud (edge case improbable vu que
  le nœud est bloqué, mais possible si le blocage est très récent) → accepté
  en v1 : on restaure quand même, le delta à rattraper est juste plus long.
  Pas de comparaison de hauteur avant restore (YAGNI pour l'instant).

## 12. Tests (devnet)

Réutiliser le pattern `scenarioN` déjà présent pour le snapshot/restore
manuel (cf. plan snapshot-restore existant) :

- **scenario-autoheal-sentry** : geler artificiellement le sentry (stop du
  process de progression, ex. couper le peering), vérifier que
  `check-stuck.sh` détecte après `STUCK_THRESHOLD` cycles, que `autoheal.sh`
  restaure et que le nœud rattrape la tête de chaîne.
- **scenario-autoheal-validator** : même chose côté validateur (mode tmkms),
  vérifier en plus qu'aucun refus « double sign » n'apparaît dans les logs
  tmkms après reprise de signature.
- **scenario-autoheal-no-snapshot** : bucket vide → vérifie que le script
  échoue proprement sans toucher aux données du nœud.
- **scenario-autoheal-cooldown** : déclenche deux blocages rapprochés,
  vérifie que le deuxième est bloqué par le lock et alerte au lieu de
  relancer un restore.

## 13. Livrables (checklist d'implémentation)

- [ ] `check-stuck.sh` (détection, état persistant, seuil configurable)
- [ ] `pull-from-s3.sh` (miroir de `push-to-s3.sh`, sélection par hauteur max)
- [ ] `autoheal.sh` (orchestrateur sentry + validateur, garde-fou local,
      cooldown, alerting)
- [ ] `restore.sh --yes`
- [ ] Units systemd `gno-autoheal-check.{service,timer}`
- [ ] Variables Ansible (`defaults/main.yml`) + `.env.example` (`WEBHOOK_URL`,
      `KEEP_LAST`, `STUCK_THRESHOLD`, cooldown, timeouts)
- [ ] README du rôle : section auto-heal + correction de la mention lifecycle
      Scaleway obsolète
- [ ] 4 scénarios devnet (§12)
