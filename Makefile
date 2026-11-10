SHELL := /bin/bash
VERSION ?=
MESSAGE ?= hello
EVENT_ID ?=
CONFIRM ?=
REPLICAS ?=

.DEFAULT_GOAL := help
.PHONY: help doctor host-bootstrap up provision git-bootstrap test status urls legacy-release \
	broadcast broadcast-status smoke handoff-plan handoff gitops-release drift-demo rollback \
	recovery-demo scale redis-info collect-evidence halt destroy argo-ui forward refresh-deploy-token

help: ## List targets and parameters
	@echo "Targets:"
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/^([a-z-]+):.*## (.*)/  \1\t\2/' | column -t -s $$'\t'
	@echo; echo "Parameters: VERSION=v1  MESSAGE=text  EVENT_ID=id  CONFIRM=lab"

doctor: ## Read-only preflight and conflict checks
	@scripts/doctor.sh

host-bootstrap: ## Install host tools for libvirt/vagrant (uses sudo)
	@scripts/host-bootstrap.sh

up: ## Create the VMs and provision the whole platform
	@scripts/vagrant.sh up
	@scripts/provision.sh
	@scripts/git-bootstrap.sh

provision: ## Idempotent provisioning, respects the delivery phase
	@scripts/provision.sh

git-bootstrap: ## Create and seed the app and env repositories
	@scripts/git-bootstrap.sh

test: ## Unit tests and real-Redis integration tests
	@scripts/test.sh

status: ## VMs, agent, platform, application, phase, desired and live version
	@scripts/status.sh

urls: ## Non-secret URLs
	@scripts/urls.sh

legacy-release: ## Run the Jenkins legacy job: make legacy-release VERSION=v1
	@test -n "$(VERSION)" || { echo "VERSION is required"; exit 2; }
	@scripts/release.sh legacy $(VERSION)

broadcast: ## Publish through the ingress: make broadcast MESSAGE=hello
	@scripts/broadcast.sh "$(MESSAGE)"

broadcast-status: ## Query a result: make broadcast-status EVENT_ID=<id>
	@test -n "$(EVENT_ID)" || { echo "EVENT_ID is required"; exit 2; }
	@scripts/broadcast.sh status $(EVENT_ID)

smoke: ## Fan-out and cross-pod checks
	@scripts/smoke-full.sh

handoff-plan: ## Register the Argo app unsynced and show the adoption diff
	@scripts/handoff-plan.sh

handoff: ## Guarded transfer of deployment ownership to Argo CD
	@scripts/handoff.sh

gitops-release: ## Run the Jenkins GitOps job: make gitops-release VERSION=v2
	@test -n "$(VERSION)" || { echo "VERSION is required"; exit 2; }
	@scripts/release.sh gitops $(VERSION)

drift-demo: ## Scale by hand, watch Argo self-heal
	@scripts/drift-demo.sh

rollback: ## Revert the last release commit in env and verify Argo
	@scripts/rollback.sh

scale: ## Scale through Git: make scale REPLICAS=5
	@test -n "$(REPLICAS)" || { echo "REPLICAS is required"; exit 2; }
	@scripts/scale.sh $(REPLICAS)

recovery-demo: ## Crash before ACK, reclaim by the replacement pod
	@scripts/recovery-demo.sh

redis-info: ## Group cursors, lag, pending and stream samples
	@scripts/redis-info.sh

collect-evidence: ## Write sanitized evidence under docs/evidence
	@scripts/collect-evidence.sh

forward: ## Forward app, Jenkins and Gitea to localhost (for Windows browsers with WSL2)
	@scripts/forward.sh

argo-ui: ## Port-forward Argo CD on 127.0.0.1:8443
	@scripts/argo-ui.sh

refresh-deploy-token: ## New Jenkins deploy token (only while phase is jenkins)
	@scripts/refresh-deploy-token.sh

halt: ## Stop only these VMs
	@scripts/vagrant.sh halt

destroy: ## Destroy this lab: make destroy CONFIRM=lab
	@test "$(CONFIRM)" = lab || { echo "refusing: run make destroy CONFIRM=lab"; exit 2; }
	@scripts/vagrant.sh destroy -f
	@rm -rf .lab/secrets .lab/state .lab/worktrees .lab/kubeconfig .lab/kubeconfig.argocd .lab/evidence
	@echo "lab destroyed (box cache and .lab/bin kept)"
