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
 │                 GitHub                       │
 │  ┌─────────────────┐  ┌─────────────────────┐│
 │  │ go-hello-app    │  │ gitops-infra-cluster││
 │  │ (GitHub Actions)│  │ (manifests)         ││
 │  └────────┬────────┘  └──────────┬──────────┘│
 └───────────┼──────────────────────┼───────────┘
             │ push image           │ polled by ArgoCD
             ▼                      ▼
    ┌────────────────┐    ┌─────────────────────────────────┐
    │  ghcr.io       │    │        VM (k3d)                 │
    │  go-hello-app  │    │                                 │
    └────────┬───────┘    │  ┌───────────────────────────┐  │
             │            │  │     cluster-hub           │  │
             │ poll       │  │ ┌──────────────────────┐  │  │
             ▼            │  │ │ ArgoCD               │  │  │
    ┌────────────────┐    │  │ │ ArgoCD Image Updater │  │  │
    │ Image Updater  │    │  │ └───────┬──────────────┘  │  │
    │ auto-updates   │    │  └─────────┼─────────────────┘  │
    │ image tag in   │    │            │ deploy             │
    │ kustomization  │    │    ┌───────┴───────┐            │
    └────────────────┘    │    ▼               ▼            │
                          │ ┌────────┐   ┌─────────┐        │
                          │ │staging │   │  prod   │        │
                          │ │1 repl  │   │3 repl   │        │
                          │ └────────┘   └─────────┘        │
                          └─────────────────────────────────┘
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
