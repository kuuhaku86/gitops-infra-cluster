# GitOps Infrastructure Cluster — Design Spec

**Date:** 2026-07-15  
**Status:** Approved

---

## Overview

A GitOps-powered multi-environment pipeline running on a single VM using k3d (Kubernetes in Docker). Three lightweight clusters form a hub-and-spoke architecture: `cluster-hub` runs ArgoCD and ArgoCD Image Updater, while `cluster-staging` and `cluster-prod` host the deployed application in separate environments.

This repository (`gitops-infra-cluster`) holds only infrastructure-as-code: cluster manifests, ArgoCD Application CRDs, kustomize overlays, and the bootstrap script. The demo application (a Go HTTP server) lives in a separate repository.

---

## Repository Structure

```
gitops-infra-cluster/
├── scripts/
│   └── bootstrap.sh                  # Creates gitops-net + 3 k3d clusters
├── argocd-apps/
│   ├── root-application.yaml         # App-of-Apps entrypoint
│   ├── staging-app.yaml              # ArgoCD Application → apps/overlays/staging
│   └── prod-app.yaml                 # ArgoCD Application → apps/overlays/prod
├── apps/
│   ├── base/
│   │   ├── deployment.yaml           # Core Deployment (container, port 8080)
│   │   ├── service.yaml              # ClusterIP Service
│   │   └── kustomization.yaml        # Resources: [deployment, service]
│   └── overlays/
│       ├── staging/
│       │   ├── patches.yaml          # APP_ENV=staging, 1 replica
│       │   └── kustomization.yaml    # resources: ../../base, patches
│       └── prod/
│           ├── patches.yaml          # APP_ENV=prod, 3 replicas, resource limits
│           └── kustomization.yaml    # resources: ../../base, patches
├── argo-image-updater/
│   └── image-updater-install.yaml    # ArgoCD Image Updater installation manifest
├── .github/
│   └── workflows/
│       └── validate-manifests.yml    # CI: kustomize build + lint
└── README.md                         # Portfolio-grade documentation
```

**Separate app repo** (`go-hello-app`, referenced but not part of this repo):

```
go-hello-app/
├── main.go                           # HTTP server on :8080, reads APP_ENV
├── Dockerfile                        # Multi-stage: Go build → scratch
├── .github/workflows/
│   └── ci.yml                        # Build, tag with datetime, push to ghcr.io
└── README.md
```

---

## Architecture & Data Flow

```
 [go-hello-app Repo]                [gitops-infra-cluster Repo]           [K3D Clusters]

 main.go push                                                             
   │                                                                      
   ▼                                                                      
 CI workflow                  ┌──────────────────────────────────────────┐
   ├─ docker build             │ docker network: gitops-net               │
   ├─ tag: YYYY-MM-DD_HH-mm-ss │                                          │
   └─ push → ghcr.io           │  ┌─────────────────────────────────────┐ │
                               │  │        cluster-hub                  │ │
                               │  │                                     │ │
                               │  │  ArgoCD ──► polls git repo          │ │
                               │  │    │                                │ │
                               │  │    ▼                                │ │
                               │  │  root-application.yaml              │ │
                               │  │    ├── staging-app.yaml             │ │
                               │  │    │   └── apps/overlays/staging    │ │
                               │  │    │       │                        │ │
                               │  │    │       ▼                        │ │
                               │  │    │   ─────────────┐               │ │
                               │  │    │   cluster-staging              │ │
                               │  │    │   (go-hello-app, 1 replica)    │ │
                               │  │    │   APP_ENV=staging              │ │
                               │  │    │   ─────────────┘               │ │
                               │  │    │                                │ │
                               │  │    └── prod-app.yaml                │ │
                               │  │        └── apps/overlays/prod       │ │
                               │  │            │                        │ │
                               │  │            ▼                        │ │
                               │  │        ────────────┐                │ │
                               │  │        cluster-prod                 │ │
                               │  │        (go-hello-app, 3 replicas)   │ │
                               │  │        APP_ENV=prod                 │ │
                               │  │        ────────────┘                │ │
                               │  │                                     │ │
                               │  │  Image Updater ←── polls ghcr.io    │ │
                               │  │    │            for newest tag      │ │
                               │  │    ▼                                │ │
                               │  │  Updates kustomization.yaml tag     │ │
                               │  │  + commits + triggers sync          │ │
                               │  └─────────────────────────────────────┘ │
                               └──────────────────────────────────────────┘
```

---

## Key Design Decisions

### Image Strategy

- **Tag format:** `YYYY-MM-DD_HH-mm-ss` (UTC), set by app repo CI: `$(date -u +%Y-%m-%d_%H-%M-%S)`
- **Also pushes `latest`** tag for convenience; not used by Image Updater
- **ArgoCD Image Updater** uses `newest-build` strategy — detects the most recently created tag in ghcr.io
- **Write-back method:** `git` — Image Updater commits the new tag back to `apps/overlays/<env>/kustomization.yaml`
- **Environment differentiation:** Via `APP_ENV` env var in patches.yaml, not via separate image tags

### Bootstrap Script vs README

- **`scripts/bootstrap.sh`** does exactly three things: creates `gitops-net` Docker network, creates 3 k3d clusters with distinct API ports (6443/6444/6445), verifies contexts
- **README** documents all subsequent manual steps in detail: ArgoCD installation, spoke cluster registration, root application, Image Updater installation
- This split shows both automation competence and deep understanding of each component

### App-of-Apps Pattern

- A single `root-application.yaml` applied once bootstraps everything
- Child apps (`staging-app.yaml`, `prod-app.yaml`) are automatically picked up and synced
- Each child app points to its overlay directory (`apps/overlays/<env>/`)
- Destination clusters are addressed via internal Docker DNS: `k3d-staging-server-0:6443`, `k3d-prod-server-0:6443`

### Kustomize Overlays

- `apps/base/` contains the shared Deployment and Service definitions
- `apps/overlays/staging/` and `apps/overlays/prod/` patch replicas, env vars, and resource limits
- Image tag override lives in overlay `kustomization.yaml` — updated by Image Updater

### Clusters & Networking

- All three k3d clusters joined to shared Docker bridge network `gitops-net`
- Hub cluster: API on host port 6443, ArgoCD UI accessible via port-forward
- Staging cluster: API on host port 6444
- Prod cluster: API on host port 6445
- Spoke registration uses internal container hostnames (no external IPs needed)

### Demo Application (Go)

- Single `main.go`, HTTP server on `:8080`
- Reads `APP_ENV` env var, responds with `"Hello from <env>"` and the version/image tag
- Multi-stage Dockerfile: `golang:alpine` for build, `scratch` for runtime (<10MB final image)
- CI in separate repo pushes to `ghcr.io/<your-github-username>/go-hello-app:<datetime>` and `:latest`
- Image tag injected into Go binary at build time via `-ldflags "-X main.Version=$TAG"` so the HTTP response includes both env and version

---

## Success Criteria

1. Running `./scripts/bootstrap.sh` creates all three clusters with correct contexts
2. Applying `root-application.yaml` deploys the app to both staging and prod clusters
3. Pushing to the app repo triggers CI → Image Updater → automatic rollout on target environments
4. Port-forwarding to the app Service returns `"Hello from staging"` or `"Hello from production"` based on which cluster's service is accessed
5. `kustomize build apps/overlays/staging` and `kustomize build apps/overlays/prod` both succeed
6. `kubectl config get-contexts` shows all three clusters after bootstrap
