# GitOps Infrastructure Cluster — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a portfolio-grade GitOps infrastructure repo that provisions a k3d hub-and-spoke cluster architecture and deploys a Go app to staging and production environments via ArgoCD App-of-Apps.

**Architecture:** Single repo containing Kustomize overlays for staging/prod, ArgoCD Application CRDs following the App-of-Apps pattern, a bootstrap script for cluster provisioning, and ArgoCD Image Updater configuration for automated image rollout.

**Tech Stack:** Bash (bootstrap), Kustomize (overlays), Kubernetes manifests (Deployment/Service), ArgoCD (GitOps controller), ArgoCD Image Updater (registry-driven updates), GitHub Actions (CI validation)

## Global Constraints

- Image tag format: `YYYY-MM-DD_HH-mm-ss` (UTC), produced by app repo CI
- Container registry: `ghcr.io/kuuhaku86/go-hello-app`
- Environment differentiation: Via `APP_ENV` env var in overlay patches, not separate image tags
- Cluster API ports: hub=6443, staging=6444, prod=6445 on shared `gitops-net` Docker network
- ArgoCD Image Updater strategy: `newest-build` with `write-back-method: git`
- Docker image: `ghcr.io/kuuhaku86/go-hello-app` on port `8080`
- Go binary: version injected via `-ldflags "-X main.Version=$TAG"`

---

### Task 1: Bootstrap Script

**Files:**
- Create: `scripts/bootstrap.sh`

**Interfaces:**
- Produces: `bootstrap.sh` — executable shell script, idempotent (skips if resources exist)

- [ ] **Step 1: Create the bootstrap script**

```bash
#!/usr/bin/env bash
set -euo pipefail

NETWORK="gitops-net"
HUBS="hub:6443"
STAGING="staging:6444"
PROD="prod:6445"

echo "==> Checking Docker network '${NETWORK}'..."
if docker network inspect "${NETWORK}" >/dev/null 2>&1; then
  echo "    Network '${NETWORK}' already exists, skipping."
else
  echo "    Creating network '${NETWORK}'..."
  docker network create "${NETWORK}"
fi

for entry in "${HUBS}" "${STAGING}" "${PROD}"; do
  name="${entry%%:*}"
  port="${entry##*:}"
  echo ""
  echo "==> Creating k3d cluster '${name}' on port ${port}..."
  if k3d cluster list 2>/dev/null | grep -q "^${name} "; then
    echo "    Cluster '${name}' already exists, skipping."
  else
    k3d cluster create "${name}" \
      --network "${NETWORK}" \
      --api-port "${port}"
  fi
done

echo ""
echo "==> Verifying contexts..."
kubectl config get-contexts --no-headers | grep -E "k3d-hub|k3d-staging|k3d-prod"

echo ""
echo "All clusters ready."
echo "Next steps (see README.md):"
echo "  1. kubectl config use-context k3d-hub"
echo "  2. Install ArgoCD on the hub cluster"
echo "  3. Register spoke clusters with ArgoCD"
echo "  4. Apply root-application.yaml"
```

- [ ] **Step 2: Make it executable and verify syntax**

Run: `chmod +x scripts/bootstrap.sh && bash -n scripts/bootstrap.sh`
Expected: No output (syntax OK)

- [ ] **Step 3: Commit**

```bash
git add scripts/bootstrap.sh
git commit -m "feat: add bootstrap script for k3d cluster provisioning"
```

---

### Task 2: Base Application Manifests

**Files:**
- Create: `apps/base/deployment.yaml`
- Create: `apps/base/service.yaml`
- Create: `apps/base/kustomization.yaml`

**Interfaces:**
- Produces:
  - `Deployment` resource named `go-hello-app` in namespace set by overlay, container port 8080, image `ghcr.io/kuuhaku86/go-hello-app`
  - `Service` resource named `go-hello-app`, ClusterIP, port 8080 targeting port 8080
  - `kustomization.yaml` listing both resources

- [ ] **Step 1: Create the base Deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: go-hello-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: go-hello-app
  template:
    metadata:
      labels:
        app: go-hello-app
    spec:
      containers:
        - name: go-hello-app
          image: ghcr.io/kuuhaku86/go-hello-app
          ports:
            - containerPort: 8080
          env:
            - name: APP_ENV
              value: "base"
```

- [ ] **Step 2: Create the base Service**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: go-hello-app
spec:
  type: ClusterIP
  selector:
    app: go-hello-app
  ports:
    - port: 8080
      targetPort: 8080
```

- [ ] **Step 3: Create the base kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

- [ ] **Step 4: Validate Kustomize build**

Run: `kustomize build apps/base/`
Expected: Rendered Deployment + Service YAML with `APP_ENV=base`

- [ ] **Step 5: Commit**

```bash
git add apps/base/
git commit -m "feat: add base application manifests (deployment, service, kustomization)"
```

---

### Task 3: Staging Overlay

**Files:**
- Create: `apps/overlays/staging/patches.yaml`
- Create: `apps/overlays/staging/kustomization.yaml`

**Interfaces:**
- Consumes: `apps/base/` manifests (Deployment, Service)
- Produces: Staging overlay that sets `APP_ENV=staging`, 1 replica

- [ ] **Step 1: Create the staging patches.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: go-hello-app
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: go-hello-app
          env:
            - name: APP_ENV
              value: "staging"
```

- [ ] **Step 2: Create the staging kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: go-hello-app-staging
nameSuffix: -staging
resources:
  - ../../base
patches:
  - path: patches.yaml
```

- [ ] **Step 3: Validate Kustomize build**

Run: `kustomize build apps/overlays/staging/`
Expected: Deployment has `namespace: go-hello-app-staging`, name suffix `-staging`, `APP_ENV=staging`, `replicas: 1`

- [ ] **Step 4: Commit**

```bash
git add apps/overlays/staging/
git commit -m "feat: add staging overlay (1 replica, APP_ENV=staging)"
```

---

### Task 4: Production Overlay

**Files:**
- Create: `apps/overlays/prod/patches.yaml`
- Create: `apps/overlays/prod/kustomization.yaml`

**Interfaces:**
- Consumes: `apps/base/` manifests (Deployment, Service)
- Produces: Production overlay that sets `APP_ENV=prod`, 3 replicas, CPU/memory limits

- [ ] **Step 1: Create the production patches.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: go-hello-app
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: go-hello-app
          env:
            - name: APP_ENV
              value: "prod"
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
```

- [ ] **Step 2: Create the production kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: go-hello-app-prod
nameSuffix: -prod
resources:
  - ../../base
patches:
  - path: patches.yaml
```

- [ ] **Step 3: Validate Kustomize build**

Run: `kustomize build apps/overlays/prod/`
Expected: Deployment has `namespace: go-hello-app-prod`, name suffix `-prod`, `APP_ENV=prod`, `replicas: 3`, resource limits present

- [ ] **Step 4: Commit**

```bash
git add apps/overlays/prod/
git commit -m "feat: add production overlay (3 replicas, APP_ENV=prod, resource limits)"
```

---

### Task 5: ArgoCD Application CRDs (App-of-Apps)

**Files:**
- Create: `argocd-apps/root-application.yaml`
- Create: `argocd-apps/staging-app.yaml`
- Create: `argocd-apps/prod-app.yaml`

**Interfaces:**
- Produces:
  - `root-application.yaml`: ArgoCD Application that watches `argocd-apps/` directory on the hub cluster
  - `staging-app.yaml`: ArgoCD Application pointing to `apps/overlays/staging` targeting `k3d-staging-server-0:6443`
  - `prod-app.yaml`: ArgoCD Application pointing to `apps/overlays/prod` targeting `k3d-prod-server-0:6443`

- [ ] **Step 1: Create root application**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/kuuhaku86/gitops-infra-cluster
    targetRevision: main
    path: argocd-apps/
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 2: Create staging application**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: go-hello-app-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/kuuhaku86/gitops-infra-cluster
    targetRevision: main
    path: apps/overlays/staging
  destination:
    server: https://k3d-staging-server-0:6443
    namespace: go-hello-app-staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 3: Create production application**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: go-hello-app-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/kuuhaku86/gitops-infra-cluster
    targetRevision: main
    path: apps/overlays/prod
  destination:
    server: https://k3d-prod-server-0:6443
    namespace: go-hello-app-prod
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 4: Validate YAML syntax**

Run: `for f in argocd-apps/*.yaml; do echo "Checking $f..." && kubectl apply --dry-run=client -f "$f" 2>&1 || true; done`
Expected: Each file parses without YAML errors (may warn about missing CRD, that's fine)

- [ ] **Step 5: Commit**

```bash
git add argocd-apps/
git commit -m "feat: add ArgoCD App-of-Apps CRDs (root, staging, prod)"
```

---

### Task 6: ArgoCD Image Updater Configuration

**Files:**
- Create: `argo-image-updater/image-updater-install.yaml`

**Interfaces:**
- Produces: Installation manifest for ArgoCD Image Updater (from upstream) plus annotation reference for spoke Application CRDs

- [ ] **Step 1: Create Image Updater install manifest**

```yaml
# ArgoCD Image Updater installation
# Source: https://github.com/argoproj-labs/argocd-image-updater
# 
# Apply with:
#   kubectl apply -n argocd -f https://github.com/argoproj-labs/argocd-image-updater/releases/latest/download/install.yaml
#
# After installation, add the following annotations to each spoke Application CRD
# to enable automatic image updates:
#
# annotations:
#   argocd-image-updater.argoproj.io/image-list: app=ghcr.io/kuuhaku86/go-hello-app
#   argocd-image-updater.argoproj.io/app.update-strategy: newest-build
#   argocd-image-updater.argoproj.io/write-back-method: git
#   argocd-image-updater.argoproj.io/write-back-target: kustomization
```

- [ ] **Step 2: Commit**

```bash
git add argo-image-updater/
git commit -m "feat: add ArgoCD Image Updater install reference and config"
```

---

### Task 7: CI Validation Workflow

**Files:**
- Create: `.github/workflows/validate-manifests.yml`

**Interfaces:**
- Produces: GitHub Actions workflow that validates all Kustomize builds on push

- [ ] **Step 1: Create the CI workflow**

```yaml
name: Validate Manifests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Kustomize
        uses: fluxcd/pkg/actions/kustomize@main
        with:
          version: 5.4.3

      - name: Validate base
        run: kustomize build apps/base/

      - name: Validate staging overlay
        run: kustomize build apps/overlays/staging/

      - name: Validate production overlay
        run: kustomize build apps/overlays/prod/

      - name: Check YAML syntax
        run: |
          for f in argocd-apps/*.yaml; do
            echo "=== $f ==="
            python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "OK"
          done
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/validate-manifests.yml
git commit -m "feat: add CI workflow to validate Kustomize builds and YAML syntax"
```

---

### Task 8: Portfolio-Grade README

**Files:**
- Create: `README.md`

**Interfaces:**
- Produces: Comprehensive README with architecture diagram (ASCII), prerequisites, local setup instructions, design decisions

- [ ] **Step 1: Create README.md**

```markdown
# GitOps Infrastructure Cluster

![Kubernetes](https://img.shields.io/badge/kubernetes-%23326ce5.svg?style=flat&logo=kubernetes&logoColor=white)
![ArgoCD](https://img.shields.io/badge/ArgoCD-%23EF7B4D.svg?style=flat&logo=argo&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/github%20actions-%232671E5.svg?style=flat&logo=githubactions&logoColor=white)
![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=flat&logo=docker&logoColor=white)

A GitOps-powered multi-environment pipeline running on a local VM using **k3d** (Kubernetes in Docker). Three lightweight clusters form a hub-and-spoke architecture with **ArgoCD** as the GitOps controller and **ArgoCD Image Updater** for automated container image rollouts.

---

## System Architecture

```
 ┌──────────────────────────────────────────────┐
 │                 GitHub                        │
 │  ┌─────────────────┐  ┌─────────────────────┐│
 │  │ go-hello-app    │  │ gitops-infra-cluster ││
 │  │ (GitHub Actions)│  │ (manifests)          ││
 │  └────────┬────────┘  └──────────┬──────────┘│
 └───────────┼──────────────────────┼───────────┘
             │ push image           │ polled by ArgoCD
             ▼                      ▼
    ┌────────────────┐    ┌──────────────────────────────┐
    │  ghcr.io        │    │        VM (k3d)              │
    │  go-hello-app   │    │                              │
    └────────┬───────┘    │  ┌────────────────────────┐  │
             │            │  │     cluster-hub         │  │
             │ poll       │  │  ┌───────────────────┐  │  │
             ▼            │  │  │ ArgoCD            │  │  │
    ┌────────────────┐    │  │ │ ArgoCD Image Updater│  │  │
    │ Image Updater  │    │  │ └───────┬───────────┘  │  │
    │ auto-updates   │    │  └─────────┼──────────────┘  │
    │ image tag in   │    │            │ deploy          │
    │ kustomization  │    │    ┌───────┴───────┐         │
    └────────────────┘    │    ▼               ▼         │
                          │ ┌────────┐   ┌─────────┐    │
                          │ │staging │   │  prod   │    │
                          │ │1 repl  │   │3 repl   │    │
                          │ └────────┘   └─────────┘    │
                          └──────────────────────────────┘
```

---

## Prerequisites

- [Docker](https://docs.docker.com/engine/install/) (with your user in the `docker` group)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [k3d](https://k3d.io/) (`curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash`)
- [kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/) (v5.x)
- [argocd CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/)

---

## Quick Start

### 1. Bootstrap the clusters

```bash
./scripts/bootstrap.sh
```

This creates a shared Docker network (`gitops-net`) and three k3d clusters:
- `k3d-hub` (API on :6443) — runs ArgoCD
- `k3d-staging` (API on :6444) — staging environment
- `k3d-prod` (API on :6445) — production environment

### 2. Install ArgoCD on the hub cluster

```bash
kubectl config use-context k3d-hub
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for ArgoCD pods to be ready:

```bash
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
```

### 3. Get the ArgoCD admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

### 4. Access the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` and log in with `admin` / the password from step 3.

### 5. Register spoke clusters

```bash
argocd cluster add k3d-staging --name staging
argocd cluster add k3d-prod --name prod
```

### 6. Deploy the applications

```bash
kubectl apply -f argocd-apps/root-application.yaml
```

ArgoCD will automatically discover `staging-app.yaml` and `prod-app.yaml` and sync them to their respective clusters.

### 7. Install ArgoCD Image Updater

```bash
kubectl apply -n argocd -f https://github.com/argoproj-labs/argocd-image-updater/releases/latest/download/install.yaml
```

Add Image Updater annotations to the staging and prod Application CRDs (see `argo-image-updater/image-updater-install.yaml` for the exact annotations).

### 8. Verify the deployment

```bash
# Check staging
kubectl config use-context k3d-staging
kubectl port-forward svc/go-hello-app-staging -n go-hello-app-staging 8081:8080

# In another terminal:
curl http://localhost:8081
# Output: Hello from staging

# Check production
kubectl config use-context k3d-prod
kubectl port-forward svc/go-hello-app-prod -n go-hello-app-prod 8082:8080

# In another terminal:
curl http://localhost:8082
# Output: Hello from production
```

---

## CI/CD Pipeline

### App Repo → Image Registry
The companion app repository (`go-hello-app`) uses GitHub Actions to:
1. Build the Go binary with version injection
2. Build a multi-stage Docker image (<10MB final size)
3. Push to `ghcr.io/kuuhaku86/go-hello-app` with tag `YYYY-MM-DD_HH-mm-ss` and `latest`

### Registry → Cluster (Image Updater)
ArgoCD Image Updater polls `ghcr.io/kuuhaku86/go-hello-app` using the `newest-build` strategy. When it detects a new image tag:
1. Updates the `newTag` field in `apps/overlays/<env>/kustomization.yaml`
2. Commits the change back to this repository (`write-back-method: git`)
3. ArgoCD detects the git change and triggers a rolling update on the target cluster

### Manifest Validation (This Repo)
On every push and PR to `main`, GitHub Actions validates:
- `kustomize build` for all three kustomization directories
- YAML syntax check for ArgoCD Application CRDs

---

## Design Decisions

**Kustomize over Helm:** Chose Kustomize for template-free, declarative environment overlays. Each environment is a thin overlay inheriting from a shared base — no templating engine, no values.yaml drift.

**k3d for local multi-cluster:** Used k3d (k3s in Docker) to simulate a hub-and-spoke topology on a single VM. Three lightweight clusters on a shared Docker bridge network mirror enterprise multi-cluster setups at zero cloud cost.

**ArgoCD Image Updater over CI-driven updates:** Decoupled the app repo from the infra repo completely. The app repo CI only builds and pushes images — it has no awareness of Kubernetes or GitOps. Image Updater independently detects new tags and drives deployments. This is the pattern used in regulated environments where app teams should not have access to infrastructure repos.

**Separate repos for app and infra:** Follows the real-world pattern of separating concerns. The infra team owns cluster configuration and deployment policies; the app team owns application code and the CI pipeline. No cross-repo write permissions needed.

**Datetime-based tagging:** Every CI build produces an immutable, unique tag (`YYYY-MM-DD_HH-mm-ss`). This gives full auditability — you can trace any deployed version back to its build timestamp without relying on mutable tags like `latest`.

---

## Companion Repositories

- **go-hello-app** — The demo Go HTTP server (`github.com/kuuhaku86/go-hello-app`). Responds with environment name and version tag.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add portfolio-grade README with architecture and setup guide"
```
