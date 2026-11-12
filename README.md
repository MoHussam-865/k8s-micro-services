# MicroCRM — Kubernetes Deployment

> **Production-grade, scalable Kubernetes deployment for the MicroCRM stack.**
> Every manifest is heavily commented to teach Kubernetes concepts, best practices,
> and the "why" behind each decision.

---

## Architecture Overview

```
                          ┌──────────────────────────┐
                          │      Internet / User      │
                          └────────────┬─────────────┘
                                       │  HTTPS (TLS)
                          ┌────────────▼─────────────┐
                          │   Ingress Controller      │  ← NGINX / Traefik
                          │   (External Entry Point)  │
                          └────────────┬─────────────┘
                                       │
                          ┌────────────▼─────────────┐
                          │   Ingress Resource        │  ← k8s/06-ingress.yaml
                          │   Host: crm.local         │
                          └────────────┬─────────────┘
                                       │
                    ┌──────────────────┴──────────────────┐
                    │                                     │
        ┌───────────▼───────────┐             ┌───────────▼───────────┐
        │  frontend-service     │             │   api-service          │
        │  (ClusterIP:3000)     │             │   (ClusterIP:4000)     │
        │                       │             │                        │
        │  ┌─────────────────┐  │             │  ┌──────────────────┐  │
        │  │  Frontend Pods  │  │             │  │   API Pods       │  │
        │  │  (replicas: 2)  │  │  /api/*     │  │  (replicas: 2)   │  │
        │  │  Next.js + SSR  │──┼─────────────┼──│  Business Logic  │  │
        │  └─────────────────┘  │   proxy     │  └────────┬─────────┘  │
        └───────────────────────┘             └───────────┼────────────┘
                                                          │
                                     ┌────────────────────┼────────────────────┐
                                     │                    │                    │
                         ┌───────────▼───────────┐ ┌──────▼──────────┐ ┌──────▼──────────────┐
                         │  postgres-service      │ │                 │ │                     │
                         │  (ClusterIP:5432)      │ │ notification-   │ │ notification-       │
                         │                        │ │ service:5000    │ │ service-hpa         │
                         │  ┌──────────────────┐  │ │                 │ │ (auto-scale: 2-10)  │
                         │  │  PostgreSQL Pod  │  │ │ ┌─────────────┐ │ └────────────────────┘
                         │  │  (replicas: 1)   │  │ │ │ Notif Pods  │ │
                         │  │  + PVC (1Gi)     │  │ │ │ (replicas:2)│ │
                         │  └──────────────────┘  │ │ └─────────────┘ │
                         └───────────────────────┘ └─────────────────┘
```

### Component Summary

| Component | Kind | Replicas | Scaling | External Access |
|---|---|---|---|---|
| PostgreSQL | Deployment + PVC | 1 (fixed) | Manual only | ❌ Internal only |
| Notification Service | Deployment + HPA | 2–10 | Auto (CPU) | ❌ Internal only |
| API Service | Deployment + HPA | 2–10 | Auto (CPU) | ❌ Optional via Ingress |
| Frontend | Deployment | 2+ | Manual (kubectl scale) | ✅ Via Ingress |

---

## Directory Structure

```
k8s-micro-services/
│
├── docker-compose.yaml          # Original Docker Compose setup (for reference)
├── implementation-guide.md      # Original Docker-based guide (for reference)
├── README.md                    # ← YOU ARE HERE
│
└── k8s/                         # All Kubernetes manifests
    │
    ├── 00-namespace.yaml        # 1⃣  Namespace isolation (crm-system)
    ├── 01-configmap.yaml        # 2⃣  Non-sensitive configuration
    ├── 01-secrets.yaml          # 2⃣  Sensitive data (passwords, tokens)
    │
    ├── 02-postgres/             # 3⃣  Database layer
    │   ├── pvc.yaml             #     Persistent storage (1Gi)
    │   ├── deployment.yaml      #     PostgreSQL deployment (replicas: 1)
    │   └── service.yaml         #     Internal ClusterIP
    │
    ├── 03-notification-service/ # 4⃣  Background service layer
    │   ├── deployment.yaml      #     Scalable deployment (replicas: 2-10)
    │   ├── service.yaml         #     Internal ClusterIP
    │   └── hpa.yaml             #     Horizontal Pod Autoscaler
    │
    ├── 04-api-service/          # 5⃣  Business logic layer
    │   ├── deployment.yaml      #     Scalable deployment (replicas: 2-10)
    │   ├── service.yaml         #     Internal ClusterIP
    │   └── hpa.yaml             #     Horizontal Pod Autoscaler
    │
    ├── 05-frontend/             # 6⃣  Presentation layer
    │   ├── deployment.yaml      #     Scalable deployment (replicas: 2+)
## Prerequisites

| Tool | Version | Check Command |
|---|---|---|
| **kubectl** | ≥ 1.28 | `kubectl version --client` |
| **Kubernetes Cluster** | ≥ 1.28 | `kubectl cluster-info` |
| **Ingress Controller** | NGINX ≥ 1.10 | `kubectl get pods -n ingress-nginx` |
| **Metrics Server** | Latest | `kubectl top nodes` |

### Setting up a local cluster

**Option A — Docker Desktop** (recommended for learning):
1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
2. Settings → Kubernetes → Enable Kubernetes → Apply & Restart
3. Verify: `kubectl cluster-info`

**Option B — minikube:**
```bash
minikube start --cpus=4 --memory=8192
minikube addons enable ingress
minikube addons enable metrics-server
```

### Install Ingress Controller (NGINX)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/cloud/deploy.yaml

# Wait for it to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

### Install Metrics Server (required for HPA)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Verify after ~60 seconds
kubectl top nodes
```
    │   └── service.yaml         #     Internal ClusterIP (exposed via Ingress)
    │
    └── 06-ingress.yaml          # 7⃣  External traffic routing
---
## Quick Start

### 1. Build Docker Images

First, build the images from your source code (these must exist before K8s can pull them):

```bash
# From your project root (where the Dockerfiles are)
docker build --build-arg NEXT_PUBLIC_API_URL=http://api-service:4000 -t frontend:latest ./frontend
docker build -t api:latest ./api-service
docker build -t notification-service:latest ./notification-service
```

> **Important:** The `--build-arg` is different from Docker Compose. In K8s, the frontend's
> `API_URL` is injected via ConfigMap, not at build time. The build arg is only needed
> if your Dockerfile uses it for the initial build.

### 2. Deploy to Kubernetes

```bash
# Apply ALL manifests in order (the numbered prefixes handle ordering)
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-configmap.yaml
kubectl apply -f k8s/01-secrets.yaml
kubectl apply -f k8s/02-postgres/
kubectl apply -f k8s/03-notification-service/
kubectl apply -f k8s/04-api-service/
kubectl apply -f k8s/05-frontend/
kubectl apply -f k8s/06-ingress.yaml
```

Or — **all at once** (K8s is declarative; it figures out order):

```bash
kubectl apply -f k8s/ --recursive
```
```

> **Numbering convention:** Files are applied in numbered order. `00-` first, then `01-`, etc.
> This ensures dependencies (Namespace → ConfigMap/Secrets → Services) are created before consumers.
### 3. Verify Everything is Running

```bash
# Check all resources in our namespace
kubectl get all -n crm-system

# Expected output:
#   NAME                                        READY   STATUS    RESTARTS
#   pod/postgres-<hash>                         1/1     Running   0
#   pod/notification-service-<hash1>            1/1     Running   0
#   pod/notification-service-<hash2>            1/1     Running   0
#   pod/api-service-<hash1>                     1/1     Running   0
#   pod/api-service-<hash2>                     1/1     Running   0
#   pod/frontend-<hash1>                        1/1     Running   0
#   pod/frontend-<hash2>                        1/1     Running   0
#
#   NAME                                  TYPE        CLUSTER-IP
#   service/postgres-service              ClusterIP   10.x.x.x
#   service/notification-service          ClusterIP   10.x.x.x
#   service/api-service                   ClusterIP   10.x.x.x
#   service/frontend-service              ClusterIP   10.x.x.x
#
#   NAME                                   READY   UP-TO-DATE   AVAILABLE
#   deployment.apps/postgres               1/1     1            1
#   deployment.apps/notification-service   2/2     2            2
#   deployment.apps/api-service            2/2     2            2
#   deployment.apps/frontend               2/2     2            2
#
#   NAME                                              DESIRED   CURRENT   READY
#   replicaset.apps/postgres-<hash>                   1         1         1
#   replicaset.apps/notification-service-<hash>       2         2         2
#   replicaset.apps/api-service-<hash>                2         2         2
#   replicaset.apps/frontend-<hash>                   2         2         2
```

> **Notice the ReplicaSets!** You see the ReplicaSets that each Deployment created for you.
> You didn't write a single ReplicaSet YAML — K8s manages them automatically.

### 4. Access the Application

**Docker Desktop:**
```
http://localhost:3000
```

**minikube** (with `minikube tunnel` running in another terminal):
```
http://crm.local         # After adding to /etc/hosts
```

**To access via Ingress (local DNS):**

Add this line to your `/etc/hosts` (macOS/Linux) or `C:\Windows\System32\drivers\etc\hosts` (Windows):
```
127.0.0.1    crm.local
```

Then visit: **http://crm.local**

Login with: `admin@crm.local` / `admin123`

---
## Scaling Guide

### Understanding What We Have

| Scaling Method | What It Does | When To Use |
|---|---|---|
| **ReplicaSet** (automatic) | Ensures N identical pods always run | Always active — it's the foundation |
| **Manual scaling** | `kubectl scale deployment X --replicas=N` | Quick adjustments, testing |
| **HPA** (auto-scaling) | Auto-adjusts replicas based on CPU/memory | Production workloads with variable load |
| **VPA** (vertical) | Increases pod CPU/memory limits | Not covered here — advanced topic |

### Manual Scaling

```bash
# Scale the frontend to 5 replicas
kubectl scale deployment frontend -n crm-system --replicas=5

# Scale the API service to 3 replicas
kubectl scale deployment api-service -n crm-system --replicas=3

# Watch the new pods spin up
kubectl get pods -n crm-system -w

# Check the ReplicaSets — you'll see the DESIRED count change
kubectl get rs -n crm-system
```

### Auto-Scaling with HPA

The HPA is already configured! Check its status:

```bash
# View HPA status
kubectl get hpa -n crm-system

# Detailed view (shows current vs target metrics)
kubectl describe hpa api-service-hpa -n crm-system
```

Example output:
```
Name:                api-service-hpa
Reference:           Deployment/api-service
Metrics:             cpu: 70% (current: 23% / target: 70%)
Min replicas:        2
Max replicas:        10
Current replicas:    2
```

**To test auto-scaling (simulate load):**

```bash
# In one terminal: generate load on the API
kubectl run -i --tty load-generator --rm --image=busybox:1.28 \
  --restart=Never -n crm-system -- \
  /bin/sh -c "while sleep 0.01; do wget -q -O- http://api-service:4000/api/health; done"

# In another terminal: watch the HPA react
kubectl get hpa -n crm-system -w
```
---
---
## Key Kubernetes Concepts Explained

### Deployment → ReplicaSet → Pod Hierarchy

```
Deployment (you create this)
  └── ReplicaSet (K8s creates and manages this automatically)
       ├── Pod-1 (your app instance)
       ├── Pod-2 (your app instance)
       └── Pod-N (your app instance)
```

- **You** define the **Deployment** — what image, how many replicas, update strategy.
- **K8s** creates the **ReplicaSet** — ensures the exact number of pods are running.
- **K8s** creates the **Pods** — the actual running containers.

When you update the image tag, K8s:
1. Creates a **new** ReplicaSet with the new image
2. Gradually creates pods in the new ReplicaSet
3. Gradually removes pods in the old ReplicaSet
4. Keeps the old ReplicaSet (scaled to 0) for easy rollback

### Services: Stable Networking for Ephemeral Pods

Pods have temporary IPs — they change every restart. Services provide a **permanent IP and DNS name**.

```
Service "api-service" (ClusterIP: 10.100.50.20)
    → DNS: api-service.crm-system.svc.cluster.local
    → Load balances to all pods with label "app: api-service"
        → Pod api-service-abc123 (IP: 10.1.0.45)
        → Pod api-service-def456 (IP: 10.1.0.46)
```

### Why PostgreSQL is Not Scaled

Databases are **stateful**. Scaling them horizontally requires:
- Data replication between instances
- Write coordination (only one primary writes)
- Complex failover

For learning, we use 1 PostgreSQL pod with persistent storage (PVC). For real production:
- Use a **StatefulSet** instead of Deployment
- Or use a **managed database service** (AWS RDS, Google Cloud SQL, Azure DB)
---
## Common Operations

### Viewing Logs

```bash
# All logs from all frontend pods
kubectl logs -n crm-system -l app=frontend --tail=100

# Stream logs from a specific deployment
kubectl logs -n crm-system deployment/api-service -f
```

### Debugging a Pod

```bash
# Get a shell inside a running pod
kubectl exec -it -n crm-system deployment/api-service -- /bin/sh

# Check environment variables
kubectl exec -n crm-system deployment/api-service -- env | sort

# Port-forward for local debugging
kubectl port-forward -n crm-system deployment/api-service 4001:4000
```

### Updating Images

```bash
# Set a new image tag
kubectl set image deployment/api-service api-service=api:v2 -n crm-system

# Watch the rolling update
kubectl rollout status deployment/api-service -n crm-system
```

### Rolling Back

```bash
# View rollout history
kubectl rollout history deployment/api-service -n crm-system

# Undo last deployment
kubectl rollout undo deployment/api-service -n crm-system

# Undo to a specific revision
kubectl rollout undo deployment/api-service -n crm-system --to-revision=2
```

### Restarting a Deployment
---
## Best Practices Implemented

| Practice | How We Implemented It |
|---|---|
| **Namespace isolation** | All resources in `crm-system` namespace |
| **Config/Secret separation** | ConfigMap for non-sensitive, Secret for passwords/tokens |
| **Resource limits** | Every container has CPU/memory requests AND limits |
| **Health checks** | Liveness + Readiness probes on every service |
| **Rolling updates** | Zero-downtime deployments with `maxUnavailable: 0` |
| **Horizontal scaling** | HPA on API and Notification services |
| **Persistent storage** | PVC for PostgreSQL data |
| **Internal-only DB** | ClusterIP Service (no external exposure) |
| **Ingress as single entry** | One Ingress routes all external traffic |
| **Label organization** | `app`, `tier` labels on all resources |

---

## Environment-Specific Overrides

For dev/staging/prod, you can modify these values **before applying**:

| Where to change | What to change |
|---|---|
| `*-deployment.yaml` | `replicas:` (start with 1 for dev, 2+ for prod) |
| `*-hpa.yaml` | `minReplicas:`, `maxReplicas:`, `averageUtilization:` |
| `01-secrets.yaml` | All password values |
| `01-configmap.yaml` | Service URLs, ports |
| `*-deployment.yaml` | `resources:` CPU/memory limits |
| `06-ingress.yaml` | `host:` domain name, TLS section |

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Pods stuck in `Pending` | Not enough CPU/memory on nodes | Reduce resource requests or add nodes |
| Pods in `CrashLoopBackOff` | App crashes on startup | Check logs: `kubectl logs <pod> -n crm-system` |
| `ErrImagePull` | Image not built or not available | Build images locally; use `imagePullPolicy: Never` |
| HPA shows `<unknown>` | Metrics Server not installed | Install Metrics Server (see Prerequisites) |
| Can't reach app via Ingress | No Ingress Controller / wrong host | Check: `kubectl get ingress -n crm-system` |
| `pg_isready` fails | PostgreSQL not fully initialized | Wait 10-20s; check logs |

---

## Cleaning Up

```bash
# Remove ALL CRM resources (keeps the namespace)
kubectl delete -f k8s/ --recursive

# Or: delete the entire namespace (removes everything in it)
kubectl delete namespace crm-system
```

---

## Next Steps (Advanced Topics)

- [ ] **StatefulSet** for PostgreSQL with replication
- [ ] **Prometheus + Grafana** for monitoring and custom HPA metrics
- [ ] **Istio Service Mesh** for traffic management, mTLS, and observability
- [ ] **Helm Charts** for templating and versioned releases
- [ ] **ArgoCD / Flux** for GitOps continuous deployment
- [ ] **Pod Disruption Budgets** (PDBs) for voluntary disruption protection
- [ ] **Network Policies** for micro-segmentation and zero-trust networking
- [ ] **Sealed Secrets / External Secrets** for secure secret management in Git

```bash
# Graceful restart (rolling)
kubectl rollout restart deployment/api-service -n crm-system

# Or: kill pods (ReplicaSet replaces them automatically)
kubectl delete pod -n crm-system -l app=api-service
```
---
## Quick Reference Card

```bash
# ── Deploy ───────────────────────────────────────────────────
kubectl apply -f k8s/ --recursive

# ── Status ───────────────────────────────────────────────────
kubectl get all -n crm-system
kubectl get hpa -n crm-system
kubectl get ingress -n crm-system

# ── Scale ────────────────────────────────────────────────────
kubectl scale deployment frontend -n crm-system --replicas=5
kubectl scale deployment api-service -n crm-system --replicas=3

# ── Logs ─────────────────────────────────────────────────────
kubectl logs -n crm-system -l app=api-service --tail=50 -f

# ── Debug ────────────────────────────────────────────────────
kubectl exec -it -n crm-system deployment/api-service -- /bin/sh
kubectl describe pod -n crm-system <pod-name>

# ── Update ───────────────────────────────────────────────────
kubectl set image deployment/api-service api-service=api:v2 -n crm-system
kubectl rollout status deployment/api-service -n crm-system

# ── Rollback ─────────────────────────────────────────────────
kubectl rollout undo deployment/api-service -n crm-system

# ── Teardown ─────────────────────────────────────────────────
kubectl delete namespace crm-system

# ── Access ───────────────────────────────────────────────────
# Frontend:  http://crm.local  (after /etc/hosts entry)
# Login:     admin@crm.local / admin123
```