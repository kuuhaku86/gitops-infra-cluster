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
     │ image tag via  │    │            │ deploy             │
     │ .argocd-source │    │    ┌───────┴───────┐            │
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
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/master/config/install.yaml
```

> **Note:** This project uses a dev build (v99.9.9) which introduces the `ImageUpdater` CRD. The version on `master` may not include this CRD — use the latest release or a newer commit if the CRD is missing.

### 8. Create required secrets

```bash
# Docker registry pull secret (creates kubernetes.io/dockerconfigjson)
kubectl create secret docker-registry ghcr-creds -n argocd \
  --docker-server=ghcr.io \
  --docker-username=kuuhaku86 \
  --docker-password=<github-pat>

# Git write-back credentials (for Image Updater to push commits)
kubectl create secret generic git-creds -n argocd \
  --from-literal=username=kuuhaku86 \
  --from-literal=password=<github-pat>
```

### 9. Apply the ImageUpdater CR

```bash
kubectl apply -f argo-image-updater/image-updater-cr.yaml
```

This CR configures:
- `alphabetical` update strategy (descending sort, picks the newest timestamp tag)
- `ignoreTags: [latest]` to exclude the stale `latest` tag in GHCR
- `pullsecret:argocd/ghcr-creds` for registry authentication
- `git:secret:argocd/git-creds` write-back to push tag updates back to this repo
- Kustomize manifest targets in `apps/overlays/<env>/.argocd-source-*.yaml`

### 10. Verify the deployment

```bash
# Check staging
kubectl config use-context k3d-staging
kubectl port-forward svc/go-hello-app-staging -n go-hello-app-staging 8081:8080

# In another terminal:
curl http://localhost:8081
# Returns an HTML page with environment, hostname, version, Go version, and server time

# Check production
kubectl config use-context k3d-prod
kubectl port-forward svc/go-hello-app-prod -n go-hello-app-prod 8082:8080

curl http://localhost:8082
```

---

## CI/CD Pipeline

### App Repo → Image Registry

The companion app repository (`go-hello-app`) uses GitHub Actions to:

1. Build the Go binary with version injection
2. Build a multi-stage Docker image (<10MB final size)
3. Push to `ghcr.io/kuuhaku86/go-hello-app` with tag `YYYY-MM-DD_HH-mm-ss`

### Registry → Cluster (Image Updater)

ArgoCD Image Updater polls `ghcr.io/kuuhaku86/go-hello-app` using the `alphabetical` strategy (filters descending sort order). The `latest` tag is excluded via `ignoreTags` since it cannot be deleted from GHCR (PAT scope limitation). When it detects a new image tag:

1. Updates `.argocd-source-go-hello-app-<env>.yaml` in each overlay directory (Kustomize manifest target)
2. Commits the change back to this repository (`write-back-method: git:secret:argocd/git-creds`)
3. ArgoCD detects the git change and triggers a rolling update on the target cluster

### Local Validation

Validate manifests before pushing:

```bash
kustomize build apps/overlays/staging
kustomize build apps/overlays/prod
```

---

## Design Decisions

**Kustomize over Helm:** Chose Kustomize for template-free, declarative environment overlays. Each environment is a thin overlay inheriting from a shared base — no templating engine, no values.yaml drift.

**k3d for local multi-cluster:** Used k3d (k3s in Docker) to simulate a hub-and-spoke topology on a single VM. Three lightweight clusters on a shared Docker bridge network mirror enterprise multi-cluster setups at zero cloud cost.

**ArgoCD Image Updater over CI-driven updates:** Decoupled the app repo from the infra repo completely. The app repo CI only builds and pushes images — it has no awareness of Kubernetes or GitOps. Image Updater independently detects new tags and drives deployments. This is the pattern used in regulated environments where app teams should not have access to infrastructure repos.

**Separate repos for app and infra:** Follows the real-world pattern of separating concerns. The infra team owns cluster configuration and deployment policies; the app team owns application code and the CI pipeline. No cross-repo write permissions needed.

**Datetime-based tagging:** Every CI build produces an immutable, unique tag (`YYYY-MM-DD_HH-mm-ss`). This gives full auditability — you can trace any deployed version back to its build timestamp without relying on mutable tags like `latest`.

**ldflags version injection:** The image tag is baked into the Go binary at compile time via `-ldflags="-X main.Version=${VERSION}"`. This means the deployed binary itself knows its version — no runtime env var or external config needed. The version is displayed on the web page alongside the environment name.

**`ImageUpdater` CR over annotations:** The dev build (v99.9.9) uses a dedicated `ImageUpdater` custom resource instead of Application annotations. This separates image-update policy from application definitions and avoids managing annotations across multiple Application CRDs.

---

## Companion Repositories

- **go-hello-app** — The demo Go HTTP server (`github.com/kuuhaku86/go-hello-app`). Serves an HTML page showing environment, hostname, version (injected via ldflags), Go version, and server time.
