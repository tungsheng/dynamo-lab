# dynamo-lab — orchestration entrypoints.
# Every target delegates to a script in scripts/. Run `make help` for the menu.
#
# Common overrides (environment or `make VAR=value`):
#   REGION          AWS region              (default us-west-2)
#   CLUSTER_NAME    EKS cluster name        (default dynamo-lab)
#   PROFILE         fleet: agg|disagg       (default agg for fleet-up)
#                   load: baseline|ramp|spike|sustained|soak (default spike)
#   TOPOLOGY        load target fleet: agg|disagg (default agg) — must match the
#                   deployed fleet; load-start does NOT auto-detect it
#   DYNAMO_VERSION  pinned Dynamo release

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

REGION       ?= us-west-2
CLUSTER_NAME ?= dynamo-lab
export REGION CLUSTER_NAME

# PROFILE is intentionally left unset by default so each target can pick its own
# default via $(or $(PROFILE),<default>).
PROFILE ?=
export PROFILE

S := scripts

.PHONY: help up down bootstrap kubeconfig infra-up infra-down \
        platform-up platform-down fleet-up fleet-down \
        chaos-start chaos-stop load-start load-stop dashboards pause resume \
        track-g-up track-g-down

help: ## Show this help
	@echo "dynamo-lab — targets:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# --- Full lifecycle -------------------------------------------------------
up: ## Full bring-up: bootstrap -> infra -> kubeconfig -> platform -> fleet(agg)
	@$(S)/up.sh

down: ## Full teardown: terraform destroy of main (idle cost -> $0)
	@$(S)/down.sh

# --- Layers ---------------------------------------------------------------
bootstrap: ## Create the S3 Terraform state bucket (idempotent)
	@$(S)/bootstrap.sh

infra-up: ## terraform apply (VPC + EKS + Karpenter IAM + system node group)
	@$(S)/infra.sh up

infra-down: ## terraform destroy of terraform/main
	@$(S)/infra.sh down

kubeconfig: ## Point kubectl at the EKS cluster
	@$(S)/kubeconfig.sh

platform-up: ## Install etcd, nats, operator, observability, chaos-mesh, karpenter
	@$(S)/platform.sh up

platform-down: ## Uninstall the in-cluster platform (helm releases)
	@$(S)/platform.sh down

# --- Fleet (fast inner loop) ---------------------------------------------
fleet-up: ## Deploy the Dynamo fleet (PROFILE=agg|disagg, default agg)
	@$(S)/fleet.sh up "$(or $(PROFILE),agg)"

fleet-down: ## Remove the Dynamo fleet (PROFILE=agg|disagg, default agg)
	@$(S)/fleet.sh down "$(or $(PROFILE),agg)"

# --- Chaos ----------------------------------------------------------------
chaos-start: ## Start the chaos monkey (Schedule + annotation bridge)
	@$(S)/chaos.sh start

chaos-stop: ## Stop the chaos monkey
	@$(S)/chaos.sh stop

# --- Load -----------------------------------------------------------------
load-start: ## Run k6 (PROFILE=baseline|ramp|spike|sustained|soak default spike; TOPOLOGY=agg|disagg default agg — set to match deployed fleet)
	@$(S)/load.sh start "$(or $(PROFILE),spike)"

load-stop: ## Stop the k6 load job
	@$(S)/load.sh stop "$(or $(PROFILE),spike)"

# --- Track G (Grove gang-scheduling, GPU-free, opt-in) --------------------
track-g-up: ## Track G: install Grove+KAI, enable on the operator, deploy the grove-scale fleet
	@GROVE=1 $(S)/platform.sh grove-up
	@$(S)/fleet.sh up grove-scale

track-g-down: ## Track G: remove the grove-scale fleet, then Grove/KAI (operator reverts to default)
	@$(S)/fleet.sh down grove-scale
	@$(S)/platform.sh grove-down

# --- Extras ---------------------------------------------------------------
dashboards: ## Port-forward Grafana and print URL + credentials
	@$(S)/dashboards.sh

pause: ## Scale all nodes to 0 (keep the cluster) for cheap suspension
	@$(S)/pause.sh

resume: ## Reverse pause: bring nodes back
	@$(S)/resume.sh
