# Pin the compose project name so the devnet network is always
# "gnoland-test_default", regardless of the directory name. The gnomonitoring
# dev stack (compose_dev_chain.yml in the gnomonitoring repository) uses the
# same project name, so the scenarios below drive its containers by service
# name. Consequence: only ONE devnet can run on a machine at a time (same
# project name, same host ports 26658-26662, 8546, 8890).
export COMPOSE_PROJECT_NAME := gnoland-test

# tmkms is opt-in (compose profile "tmkms"). By default `validator` signs
# locally and no tmkms container runs. Pass TMKMS=1 to every lifecycle command
# (or 'export TMKMS=1') to move its signing to the tmkms sidecar:
#   make up TMKMS=1
# Both settings must change together, so they are derived from one flag.
TMKMS ?=
ifeq ($(TMKMS),1)
export TMKMS_LISTEN_ADDR := unix:///run/gnoland/privval.sock
export COMPOSE_PROFILES := tmkms
endif
# Every profile, for commands that must reach every container (down, clean).
ALL_PROFILES := --profile phase2 --profile snapshot --profile tmkms

DEV_HOME := $(CURDIR)/.gnokey-dev
DEV_PASS := devpassword123
RPC      := http://localhost:26658

# Live addresses (VALIDATOR4_ADDR/PUB, VALIDATOR4_OP_ADDR, DEV_ADDR) are no longer
# hardcoded: keys are regenerated on every fresh setup, so bootstrap.sh writes
# them to .devaddrs.mk (gitignored) and we include them here. The leading "-"
# means make won't fail if it's missing (run 'make full-reinit' to generate it).
-include .devaddrs.mk

# gnomonitoring backend Postgres - used to purge the local "dev" chain data on
# every reinit, so validator metrics / participation don't carry stale block
# heights from the previous chain instance.
PG_CONTAINER := gnomonitoring-postgres
PG_USER      := gnomonitoring
PG_DB        := gnomonitoring
DEV_CHAIN    := dev

# Full local stack (this devnet + gnomonitoring backend + Postgres), defined by
# compose_dev_chain.yml in a gnomonitoring checkout. Default: the sibling
# checkout next to gno-validator-tools. Override:
#   make dev-up GNOMONITORING_DIR=/path/to/gnomonitoring
# compose_dev_chain.yml finds this directory through DEVNET_DIR.
# Both env files are needed: compose interpolates ${DOCKER_USER}/${GNO_IMAGE}
# (this directory's .env) and ${POSTGRES_PASSWORD} (gnomonitoring's .env)
# before reading any service env_file.
GNOMONITORING_DIR ?= $(abspath $(CURDIR)/../../gnomonitoring)
export DEVNET_DIR := $(CURDIR)
DEV_COMPOSE := docker compose -f $(GNOMONITORING_DIR)/compose_dev_chain.yml \
               --env-file $(GNOMONITORING_DIR)/.env --env-file $(CURDIR)/.env

.PHONY: help dev-up dev-down dev-logs up up-full up-validator4 up-snapshotter ensure-bootstrap check-signer-mode \
        down reinit regen-genesis full-reinit clean-db clean-all status logs \
        stop-val1 stop-val2 stop-val3 stop-val4 \
        start-val1 start-val2 start-val3 start-val4 \
        check-stuck autoheal snapshot snapshots restore-fullnode restore-validator \
        scenario1 scenario1-propose scenario1-execute scenario2 scenario2-restart scenario3 scenario3-restart \
        scenario4 scenario4-restart scenario5 scenario-mute scenario-govdao-dead-chain scenario-halt \
        scenario-autoheal-follower scenario-autoheal-validator scenario-autoheal-no-snapshot scenario-autoheal-cooldown

help:
	@echo "Full stack (devnet + gnomonitoring, $(GNOMONITORING_DIR)/compose_dev_chain.yml):"
	@echo "  make dev-up            - tear down, reset the chain to block 0, purge dev DB rows, start everything"
	@echo "  make dev-down          - stop and remove the whole stack (keeps the Postgres volume)"
	@echo "  make dev-logs          - follow the gnomonitoring backend logs"
	@echo ""
	@echo "Chain lifecycle:"
	@echo "  make up                - start validator/validator2/validator3 + tx-indexer + gnoweb (local signing)"
	@echo "  make up TMKMS=1        - same, with validator signing through the tmkms sidecar (profile tmkms)"
	@echo "  make up-full           - up TMKMS=1 + validator4 + snapshotter: what the auto-heal scenarios need"
	@echo "  make up-validator4     - start validator4 (phase2 profile, needed for scenario1)"
	@echo "  make down              - stop and remove all containers"
	@echo "  make reinit            - wipe chain state + purge dev-chain DB rows, restart from existing genesis.json"
	@echo "  make regen-genesis     - delete + regenerate genesis.json (after editing generate-genesis.sh)"
	@echo "  make full-reinit       - regen-genesis + reinit + up (use after changing powers/params)"
	@echo "  make clean-db          - purge local dev-chain rows from the gnomonitoring DB (keeps Telegram subs)"
	@echo "  make clean-all         - nuke ALL generated state (keys/genesis/config) -> full regen on next full-reinit"
	@echo "  make status            - docker compose ps + height/catching_up per node"
	@echo "  make logs              - follow logs of all containers"
	@echo ""
	@echo "Snapshots & restore (see SNAPSHOT-RESTORE.md):"
	@echo "  make up-snapshotter    - start the dedicated non-signing snapshot node (profile snapshot)"
	@echo "  make snapshot          - capture one chain snapshot from the snapshotter (+ rotate)"
	@echo "  make snapshots         - list available snapshot archives"
	@echo "  make restore-fullnode NODE=<svc> SNAP=<file> - restore a full node from a snapshot"
	@echo "  make restore-validator SNAP=<file>           - restore the validator (tmkms checklist prompt)"
	@echo "  make check-stuck NODE=<svc>   - run one stuck-detection check on <svc>"
	@echo "  make autoheal NODE=<svc>      - manually trigger the auto-heal restore on <svc>"
	@echo ""
	@echo "Auto-heal scenarios (run 'make up-full' and 'make snapshot' first):"
	@echo "  make scenario-autoheal-follower  - stop validator4, force-restore it, network stays healthy"
	@echo "  make scenario-autoheal-validator - force auto-heal restore of the tmkms validator, network stays healthy"
	@echo "  make scenario-autoheal-no-snapshot - autoheal aborts cleanly with no snapshot available"
	@echo "  make scenario-autoheal-cooldown  - second auto-heal within cooldown is blocked"
	@echo ""
	@echo "Per-validator control:"
	@echo "  make stop-val1..4      - docker compose stop validator[N]"
	@echo "  make start-val1..4     - docker compose start validator[N]"
	@echo ""
	@echo "Test scenarios (see README.md for details):"
	@echo "  make scenario1         - GovDAO: init DAO, register & onboard validator4"
	@echo "                           (targets proposal #0 - run 'make reinit' first"
	@echo "                           if this isn't the first proposal on the chain)"
	@echo "  make scenario2         - stop validator4 (downtime: WARNING then CRITICAL)"
	@echo "                           (run scenario1 first so validator4 is in the valset)"
	@echo "  make scenario2-restart - restart validator4 (expect RESOLVED)"
	@echo "  make scenario3         - stop validator2+validator3 (halt the chain -> stagnation)"
	@echo "  make scenario3-restart - restart validator2+validator3"
	@echo "  make scenario4         - stop ALL validators (RPC-error alert, LOG-ONLY)"
	@echo "  make scenario4-restart - restart all validators"
	@echo "  make scenario5         - GovDAO proposal voted NO (rejected-status path; fresh chain)"
	@echo "  make scenario-mute     - keep validator4 down to exercise the resend dedup"
	@echo "  make scenario-govdao-dead-chain"
	@echo "                         - a 2nd chain with hanging RPCs must not delay dev's"
	@echo "                           GovDAO ACCEPTED notice (dev stack, fresh chain; asserts, ~10 min)"
	@echo "  make scenario-halt     - GovDAO-voted chain halt: scheduled notice, 2 reminders,"
	@echo "                           resumed notice (dev stack, gno >= v1.8.0; asserts, ~10 min)"

# Guard: the generated .env (P2P seeds) and genesis.json are required for the
# chain to form. docker-compose has no default for SEEDS_*, so a missing .env
# would start validators with empty peers and the chain would silently never
# produce blocks. Bootstrap (idempotent) if either is missing.
ensure-bootstrap:
	@if [ ! -f .env ] || [ ! -f genesis.json ]; then \
		echo "ℹ️  .env/genesis.json missing — running bootstrap.sh first..."; \
		./bootstrap.sh; \
	fi

# Refuse to switch the validator's signer in the middle of a chain. Local
# signing guards double-signing with priv_validator_state.json, tmkms with its
# own consensus_state.json; neither follows the other, so a switch can sign a
# height twice. .signer-mode (gitignored) records the mode the current chain
# was started with: 'make up' writes it once compose succeeded; the chain
# resets clear it (reinit-chain.sh, clean-all) or set it to local
# (dev-chain-reset.sh, the dev stack has no tmkms).
SIGNER_MODE := $(if $(filter 1,$(TMKMS)),tmkms,local)
check-signer-mode:
	@have="$$(cat .signer-mode 2>/dev/null)"; \
	if [ -n "$$have" ] && [ "$$have" != "$(SIGNER_MODE)" ]; then \
		echo "❌ this chain runs with $$have signing; this command asks for $(SIGNER_MODE) signing."; \
		echo "   Keep the same TMKMS value, or switch on a fresh chain: make reinit$(if $(filter 1,$(TMKMS)), TMKMS=1,)"; \
		exit 1; \
	fi

# The stack is always torn down first: the chain-reset service only wipes
# chain state when the validators are not running, so 'dev-up' guarantees a
# fresh chain on every call. validator4 (phase2) is not started here; run
# 'make scenario1' to onboard it. The dev stack has no tmkms and no snapshotter.
dev-up: ensure-bootstrap
	@test -f $(GNOMONITORING_DIR)/compose_dev_chain.yml || { \
		echo "❌ $(GNOMONITORING_DIR)/compose_dev_chain.yml missing - set GNOMONITORING_DIR to a gnomonitoring checkout"; exit 1; }
	@grep -q '$${DEVNET_DIR' $(GNOMONITORING_DIR)/compose_dev_chain.yml || { \
		echo "❌ $(GNOMONITORING_DIR)/compose_dev_chain.yml does not use DEVNET_DIR: that gnomonitoring"; \
		echo "   checkout still runs its own gnoland-test/ devnet. Update it, or use its gnoland-test/."; exit 1; }
	@test "$(TMKMS)" != "1" || { echo "❌ the gnomonitoring dev stack has no tmkms: run dev-up without TMKMS=1"; exit 1; }
	@test -f $(GNOMONITORING_DIR)/.env || { echo "❌ $(GNOMONITORING_DIR)/.env missing - copy it from .env.example there"; exit 1; }
	@test -f $(GNOMONITORING_DIR)/backend/config_dev_chain.yaml || { \
		echo "❌ $(GNOMONITORING_DIR)/backend/config_dev_chain.yaml missing - copy it from config_dev_chain.yaml.template"; exit 1; }
	docker compose $(ALL_PROFILES) down --remove-orphans
	$(DEV_COMPOSE) --profile phase2 down --remove-orphans
	$(DEV_COMPOSE) up -d --build

dev-down:
	$(DEV_COMPOSE) --profile phase2 down --remove-orphans

dev-logs:
	docker logs -f gnomonitoring-backend

up: ensure-bootstrap check-signer-mode
	docker compose up -d
	@echo "$(SIGNER_MODE)" > .signer-mode

# Everything the auto-heal scenarios need: tmkms-backed validator, validator4
# and the snapshotter. Then take a first snapshot with 'make snapshot'.
up-full:
	@$(MAKE) --no-print-directory up TMKMS=1
	docker compose --profile phase2 --profile snapshot up -d validator4 snapshotter

up-validator4: ensure-bootstrap
	docker compose --profile phase2 up -d validator4

# Start the dedicated non-signing snapshot follower. It syncs the chain over
# P2P; snapshot.sh briefly stops it to tar its db (no impact on validators).
up-snapshotter: ensure-bootstrap
	docker compose --profile snapshot up -d snapshotter

down:
	docker compose $(ALL_PROFILES) down

reinit: clean-db
	./reinit-chain.sh
	@$(MAKE) --no-print-directory up

regen-genesis:
	rm -f genesis.json
	./bootstrap.sh

full-reinit: regen-genesis clean-db
	./reinit-chain.sh
	@$(MAKE) --no-print-directory up

# Purge the local "dev" chain rows from the gnomonitoring backend DB. Chain data
# only (participation, monikers, govdao proposals, aggregates, alert logs).
# Telegram subscriptions are intentionally KEPT so alerts are still delivered on
# the next test run. No-op (with a notice) if the Postgres container isn't up.
clean-db:
	@if docker ps --format '{{.Names}}' | grep -qx '$(PG_CONTAINER)'; then \
		echo "🧹 Purging chain '$(DEV_CHAIN)' data from DB '$(PG_DB)' (keeping Telegram subs)..."; \
		docker exec $(PG_CONTAINER) psql -U $(PG_USER) -d $(PG_DB) \
			-c "DELETE FROM daily_participations WHERE chain_id='$(DEV_CHAIN)';" \
			-c "DELETE FROM addr_monikers WHERE chain_id='$(DEV_CHAIN)';" \
			-c "DELETE FROM govdaos WHERE chain_id='$(DEV_CHAIN)';" \
			-c "DELETE FROM daily_participation_agregas WHERE chain_id='$(DEV_CHAIN)';" \
			-c "DELETE FROM alert_logs WHERE chain_id='$(DEV_CHAIN)';" \
		|| echo "⚠️  DB purge failed (continuing with chain reinit anyway)"; \
	else \
		echo "ℹ️  $(PG_CONTAINER) not running — skipping DB purge."; \
	fi

# Nuke ALL generated devnet state so the next 'make full-reinit' regenerates
# keys, accounts, genesis and config from scratch (fresh addresses everywhere).
# None of this is committed (see .gitignore). Uses a throwaway alpine container
# to delete files that docker may have created as root.
clean-all: clean-db
	docker compose $(ALL_PROFILES) down -v 2>/dev/null || true
	@echo "🧨 Removing all generated devnet artifacts (keys, genesis, config, keybase, snapshots)..."
	docker run --rm -v "$(CURDIR):/work" -w /work alpine sh -c \
		'rm -rf validator/gnoland-data validator2/gnoland-data validator3/gnoland-data validator4/gnoland-data snapshotter/gnoland-data \
		        validator/genesis.json validator2/genesis.json validator3/genesis.json validator4/genesis.json snapshotter/genesis.json \
		        validator/config.toml validator2/config.toml validator3/config.toml validator4/config.toml snapshotter/config.toml \
		        .gnokey-dev genesis.json genesis_balances.txt config.toml .env .devaddrs.mk .signer-mode \
		        tmkms/*/secrets tmkms/run snapshots \
		        init-govdao.gno propose-validator4.gno'
	@echo "✅ Clean. Run 'make full-reinit' to regenerate everything from scratch."

status:
	docker compose ps
	@for port in 26658 26659 26660 26661; do \
		echo "--- localhost:$$port ---"; \
		curl -s http://localhost:$$port/status | jq -r '.result.sync_info | {latest_block_height, catching_up}' 2>/dev/null || echo "unreachable"; \
	done

logs:
	docker compose logs -f

stop-val1:
	docker compose stop validator
stop-val2:
	docker compose stop validator2
stop-val3:
	docker compose stop validator3
stop-val4:
	docker compose stop validator4

start-val1:
	docker compose start validator
start-val2:
	docker compose start validator2
start-val3:
	docker compose start validator3
start-val4:
	docker compose start validator4

check-stuck: ## make check-stuck NODE=validator2
	./check-stuck.sh $(NODE)

autoheal: ## make autoheal NODE=validator2  (manual trigger, bypasses detection)
	./autoheal.sh $(NODE)

# Capture a chain snapshot from the snapshotter node (db only, wal excluded),
# then rotate to the RETENTION most recent. Override retention: RETENTION=48 make snapshot
snapshot:
	./snapshot.sh

snapshots:
	@ls -1t snapshots/*.tar.zst 2>/dev/null || echo "No snapshots yet (run 'make up-snapshotter' then 'make snapshot')."

# Restore any full node from a snapshot: make restore-fullnode NODE=snapshotter SNAP=snapshots/<file>
restore-fullnode:
	@test -n "$(NODE)" || { echo "Set NODE=<service> (e.g. NODE=snapshotter)"; exit 2; }
	@test -n "$(SNAP)" || { echo "Set SNAP=<snapshots/file.tar.zst>"; exit 2; }
	./restore.sh "$(NODE)" "$(SNAP)"

# Restore the validator (prompts the tmkms anti-double-sign checklist):
#   make restore-validator SNAP=snapshots/<file>
restore-validator:
	@test -n "$(SNAP)" || { echo "Set SNAP=<snapshots/file.tar.zst>"; exit 2; }
	./restore.sh validator "$(SNAP)"

scenario1: up-validator4
	@$(MAKE) --no-print-directory scenario1-propose
	@$(MAKE) --no-print-directory scenario1-execute

# scenario1 in two halves: scenario-govdao-dead-chain makes sure proposal #0 is
# tracked as IN PROGRESS between the two, so its later ACCEPTED is a live
# status change the watcher announces.
scenario1-propose: up-validator4
	@echo ">>> Step 1: initialize GovDAO (InitWithUsers)"
	@if gnokey query vm/qeval -remote $(RPC) \
		-data 'gno.land/r/gov/dao.AllowedDAOs()' 2>/dev/null | grep -q 'gno.land/r/gov/dao/v3/impl'; then \
		echo "    GovDAO already initialized on this chain (AllowedDAOs locked to v3/impl) - skipping."; \
		echo "    (InitWithUsers is one-shot per chain lifetime; run 'make reinit' first for a clean re-init)"; \
	else \
		echo "$(DEV_PASS)" | gnokey maketx run \
			-gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
			-chainid dev -remote $(RPC) \
			-home "$(DEV_HOME)" -insecure-password-stdin \
			dev init-govdao.gno; \
	fi
	@echo ">>> Step 2: validator4 pubkey (from committed secrets)"
	@echo "    address: $(VALIDATOR4_ADDR)"
	@echo "    pub_key: $(VALIDATOR4_PUB)"
	@echo ">>> Step 3: register validator4 as a valoper (signed by v4op operator account)"
	echo "$(DEV_PASS)" | gnokey maketx call \
		-pkgpath gno.land/r/gnops/valopers -func Register \
		-args "samourai-crew-4" \
		-args "Phase 2 test validator for gnomonitoring" \
		-args "on-prem" \
		-args $(VALIDATOR4_OP_ADDR) \
		-args $(VALIDATOR4_PUB) \
		-send 20000000ugnot -gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
		-chainid dev -remote $(RPC) \
		-home "$(DEV_HOME)" -insecure-password-stdin v4op
	@echo ">>> Step 4: create GovDAO proposal (expects #0)"
	echo "$(DEV_PASS)" | gnokey maketx run \
		-gas-fee 1000000ugnot -gas-wanted 100000000 -broadcast \
		-chainid dev -remote $(RPC) \
		-home "$(DEV_HOME)" -insecure-password-stdin \
		dev propose-validator4.gno

scenario1-execute:
	@echo ">>> Step 5: vote YES on proposal #0"
	echo "$(DEV_PASS)" | gnokey maketx call \
		-pkgpath gno.land/r/gov/dao -func MustVoteOnProposalSimple \
		-args 0 -args YES \
		-gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
		-chainid dev -remote $(RPC) \
		-home "$(DEV_HOME)" -insecure-password-stdin dev
	@echo ">>> Step 6: execute proposal #0"
	echo "$(DEV_PASS)" | gnokey maketx call \
		-pkgpath gno.land/r/gov/dao -func ExecuteProposal \
		-args 0 \
		-gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
		-chainid dev -remote $(RPC) \
		-home "$(DEV_HOME)" -insecure-password-stdin dev
	@echo ">>> Step 7: verify validator4 joined the valset"
	gnokey query vm/qeval \
		-data 'gno.land/r/sys/validators/v3.IsValidator("$(VALIDATOR4_ADDR)")' \
		-remote $(RPC)
	curl -s http://localhost:26661/status | jq '.result.validator_info'

scenario2:
	docker compose stop validator4
	@echo "validator4 stopped. Watch for a WARNING alert (>=5 missed blocks),"
	@echo "then CRITICAL (>=30 missed blocks)."

scenario2-restart:
	docker compose start validator4
	@echo "validator4 restarted. Expect a RESOLVED alert once it participates again."

scenario3:
	docker compose stop validator2 validator3
	@echo "validator2+validator3 stopped (11/31 power left, below the 2/3 supermajority)."
	@echo "Watch gnoland_chain_current_height (should stop increasing) and the"
	@echo "global stagnation/RPC-error alert."

scenario3-restart:
	docker compose start validator2 validator3
	@echo "If the chain doesn't resume producing blocks within ~1-2 min, run 'make reinit'."

# scenario4: total RPC outage. Distinct from scenario3 (stagnation): there the
# chain is reachable but stuck; here EVERY RPC endpoint is down, so the backend's
# fallback client can't reach the node at all. This alert is LOG-ONLY: it does
# NOT write to alert_logs and does NOT hit webhooks (see gnovalidator_realtime.go).
scenario4:
	docker compose --profile phase2 stop validator validator2 validator3 validator4
	@echo "All validators stopped -> every RPC endpoint is unreachable."
	@echo "Expect a LOG-ONLY alert (no alert_logs row, no webhook):"
	@echo "  docker logs gnomonitoring-backend | grep 'Error when querying latest block height'"
	@echo "It fires once, then is suppressed for the RPC-error cooldown (~10 min)."

scenario4-restart:
	docker compose --profile phase2 start validator validator2 validator3 validator4
	@echo "Validators restarted. The monitor loop should resume fetching heights."

# scenario5: GovDAO rejection path. Mirrors scenario1 but votes NO, so the
# proposal is rejected instead of onboarding validator4. This exercises the
# GovDAO watcher's CheckProposalStatus (status -> REJECTED + notification).
# Run on a FRESH chain (targets proposal #0): 'make reinit && make scenario5'.
scenario5: up-validator4
	@echo ">>> Rejected-proposal scenario (FRESH chain expected: targets proposal #0)"
	@echo ">>> Step 1: initialize GovDAO (skipped if already initialized)"
	@if gnokey query vm/qeval -remote $(RPC) \
		-data 'gno.land/r/gov/dao.AllowedDAOs()' 2>/dev/null | grep -q 'gno.land/r/gov/dao/v3/impl'; then \
		echo "    GovDAO already initialized - skipping."; \
	else \
		echo "$(DEV_PASS)" | gnokey maketx run \
			-gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
			-chainid dev -remote $(RPC) \
			-home "$(DEV_HOME)" -insecure-password-stdin \
			dev init-govdao.gno; \
	fi
	@echo ">>> Step 2: register validator4 as a valoper (signed by v4op)"
	echo "$(DEV_PASS)" | gnokey maketx call \
		-pkgpath gno.land/r/gnops/valopers -func Register \
		-args "samourai-crew-4" \
		-args "Phase 2 test validator for gnomonitoring" \
		-args "on-prem" \
		-args $(VALIDATOR4_OP_ADDR) \
		-args $(VALIDATOR4_PUB) \
		-send 20000000ugnot -gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
		-chainid dev -remote $(RPC) \
		-home "$(DEV_HOME)" -insecure-password-stdin v4op
	@echo ">>> Step 3: create GovDAO proposal (expects #0)"
	echo "$(DEV_PASS)" | gnokey maketx run \
		-gas-fee 1000000ugnot -gas-wanted 100000000 -broadcast \
		-chainid dev -remote $(RPC) \
		-home "$(DEV_HOME)" -insecure-password-stdin \
		dev propose-validator4.gno
	@echo ">>> Step 4: vote NO on proposal #0"
	echo "$(DEV_PASS)" | gnokey maketx call \
		-pkgpath gno.land/r/gov/dao -func MustVoteOnProposalSimple \
		-args 0 -args NO \
		-gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
		-chainid dev -remote $(RPC) \
		-home "$(DEV_HOME)" -insecure-password-stdin dev
	@echo ">>> Step 5: settle proposal #0 via ExecuteProposal"
	@echo "    A NO supermajority alone does NOT mark a proposal rejected on chain:"
	@echo "    gov/dao v3 only sets Denied inside PreExecuteProposal. Without this"
	@echo "    call the proposal renders 'open for votes' forever and the watcher"
	@echo "    has nothing to report. The call returns false (the payload is NOT"
	@echo "    executed, validator4 is NOT onboarded) but flips the status."
	echo "$(DEV_PASS)" | gnokey maketx call \
		-pkgpath gno.land/r/gov/dao -func ExecuteProposal \
		-args 0 \
		-gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
		-chainid dev -remote $(RPC) \
		-home "$(DEV_HOME)" -insecure-password-stdin dev
	@echo ">>> Done. The render now carries 'PROPOSAL HAS BEEN DENIED'. Expect a"
	@echo ">>> rejection notification on Discord/Slack/Telegram, and status=REJECTED:"
	@echo "  docker exec gnomonitoring-postgres psql -U gnomonitoring -d gnomonitoring \\"
	@echo "    -c \"SELECT id, status, status_synced FROM govdaos WHERE chain_id='dev';\""
	@echo ">>> Note: the watcher polls every 5 minutes, so allow one cycle."

# scenario-mute: NOT a separate chain action - it asserts the resend DEDUP
# (CLAUDE.md's "4 repeats -> MUTED" is outdated; the real rule is one alert per
# level per validator within the resend window: WARNING=6h, CRITICAL=24h, unless
# a RESOLVED was sent). Keep validator4 down across several alert-check cycles.
scenario-mute:
	docker compose stop validator4
	@echo "validator4 stopped. The FIRST WARNING/CRITICAL is written to alert_logs;"
	@echo "every later check within the resend window is SKIPPED (no new row)."
	@echo "Assert exactly ONE row per level:"
	@echo "  docker exec gnomonitoring-postgres psql -U gnomonitoring -d gnomonitoring \\"
	@echo "    -c \"SELECT level, count(*) FROM alert_logs WHERE chain_id='dev' AND addr='$(VALIDATOR4_ADDR)' GROUP BY level;\""
	@echo "And confirm the dedup log line appears:"
	@echo "  docker logs gnomonitoring-backend | grep 'dedup: skipping'"
	@echo "Restart with: make scenario2-restart"

# Neither this scenario nor scenario-autoheal-validator halts the network:
# the real incident auto-heal protects against is a single node falling
# behind/crashing while the rest of the network stays healthy — confirmed
# against a real production restore that needed no consensus_state changes
# at all. Stopping validator4 here makes its RPC unreachable, which
# check-stuck.sh correctly treats as DOWN (not "stuck") and never
# auto-triggers on — so this scenario forces autoheal.sh directly rather
# than going through detection. Known limitation: no scenario in this
# devnet suite live-exercises check-stuck.sh's actual stuck-counter/
# threshold logic end-to-end (it's covered by code review only, see Task 1)
# — simulating "RPC alive but height frozen" for a single node isn't
# practical with the primitives available here.
scenario-autoheal-follower: up-validator4
	@echo "==> Stopping validator4 (simulating a crashed/down follower node)"
	docker compose stop validator4
	@echo "==> Network stays healthy (validator/validator2/validator3 keep producing blocks)"
	@echo "==> Forcing an auto-heal restore on validator4 directly"
	./autoheal.sh validator4
	@echo "==> Confirm validator4 caught up and is producing new blocks with the rest of the network:"
	curl -s http://localhost:26661/status | jq -r '.result.sync_info'
	$(MAKE) status

# See the comment on scenario-autoheal-follower above: same rationale,
# applied to the tmkms-signing validator instead of a plain follower. This
# is the scenario that matters most for anti-double-sign confidence — it
# forces the validator-specific restart/rejoin/live-signing path directly.
scenario-autoheal-validator:
	@test "$$(cat .signer-mode 2>/dev/null)" = tmkms && \
	 test -n "$$(docker compose --profile tmkms ps -q --status running tmkms)" || { \
		echo "❌ tmkms is not running: this scenario needs the tmkms-backed validator ('make up-full')."; exit 1; }
	@echo "==> Network stays healthy (validator2/3/4 keep producing blocks) — forcing an auto-heal restore on the tmkms validator directly"
	./autoheal.sh validator
	@echo "==> Confirm the validator resumed LIVE signing (no 'double sign' refusal in tmkms logs):"
	sleep 15
	docker compose --profile tmkms logs tmkms --tail 30 | grep -i "sign" || echo "(no sign-related log lines yet)"
	@echo "==> Confirm validator is live and in sync with the rest of the network:"
	curl -s http://localhost:26658/status | jq -r '.result.sync_info'
	$(MAKE) status

scenario-autoheal-no-snapshot:
	@echo "==> Temporarily hiding snapshots/ to force a no-snapshot failure"
	mv snapshots snapshots.scenario-bak 2>/dev/null || true
	mkdir snapshots
	./autoheal.sh validator4; echo "exit=$$?  (expect 1)"
	rm -rf snapshots
	mv snapshots.scenario-bak snapshots

scenario-autoheal-cooldown:
	@echo "==> First run (expect success or a real failure, but the lock gets written)"
	-./autoheal.sh validator4
	@echo "==> Second run immediately after (expect cooldown-blocked, exit 1)"
	./autoheal.sh validator4; echo "exit=$$?  (expect 1)"

# scenario-govdao-dead-chain: reproduces the 2026-11-09 incident, where an
# enabled chain whose RPC endpoints hang delayed every chain's GovDAO status
# notifications by about an hour, and checks the fix end to end. Unlike the
# scenarios above it asserts the outcome itself and exits non-zero on failure.
# Runs on the dev stack, fresh chain expected (targets proposal #0): 'make dev-up'
# first. See the header of scenario-govdao-dead-chain.sh for the steps.
scenario-govdao-dead-chain: up-validator4
	MAKE="$(MAKE)" DEV_COMPOSE="$(DEV_COMPOSE)" GNOMONITORING_DIR="$(GNOMONITORING_DIR)" RPC="$(RPC)" \
		PG_CONTAINER="$(PG_CONTAINER)" PG_USER="$(PG_USER)" PG_DB="$(PG_DB)" ./scenario-govdao-dead-chain.sh

# scenario-halt: schedules a chain halt by GovDAO vote (r/sys/params
# NewSetHaltRequest, gno v1.8.0 or later) and checks the halt notices: scheduled,
# both reminders, resumed. Runs on the dev stack ('make dev-up' first). Asserts
# the outcome itself and exits non-zero on failure. See the header of
# scenario-halt.sh for the steps.
scenario-halt:
	DEV_COMPOSE="$(DEV_COMPOSE)" RPC="$(RPC)" PG_CONTAINER="$(PG_CONTAINER)" PG_USER="$(PG_USER)" \
		PG_DB="$(PG_DB)" DEV_HOME="$(DEV_HOME)" DEV_PASS="$(DEV_PASS)" ./scenario-halt.sh
