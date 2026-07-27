# MaximusLab OG — Kubernetes Deployment

> *"The adventure starts now. No map. No ceiling. No excuses."*

Production-ready deployment of the MaximusLab OG website on a home lab Kubernetes cluster, served via Nginx and exposed through an Ingress controller.

---

## Project Structure

```
maximuslab-og/
├── index.html              # Website (HTML + CSS + JS)
├── hero.jpeg               # Hero image
├── nginx.conf              # Nginx config (gzip, caching, /healthz probe)
├── Dockerfile              # FROM nginx:latest
├── k8s-deployment.yaml     # Full Kubernetes manifests
└── README.md               # This file
```

---

## Cluster Resources

| Resource | Name | Namespace |
|---|---|---|
| Namespace | `maximuslabog` | — |
| Deployment | `maximuslabog-web` | `maximuslabog` |
| Service | `maximuslabog-web` | `maximuslabog` |
| Ingress | `maximuslabog-web` | `maximuslabog` |

---

## Registry & Image

| Setting | Value |
|---|---|
| Registry | `192.168.2.128:8082` |
| Image | `maximuslabog-web` |
| Tag | `v1` |
| Pull Policy | `Always` |
| Full image ref | `192.168.2.128:8082/maximuslabog-web:v1` |

---

## Build & Push

```bash
# Build the image
docker build -t maximuslabog-web:v1 .

# Tag for your local registry
docker tag maximuslabog-web:v1 192.168.2.128:8082/maximuslabog-web:v1

# Push to registry
docker push 192.168.2.128:8082/maximuslabog-web:v1
```

> **Note:** If your registry uses HTTP (not HTTPS), add it to Docker's insecure registries.
>
> On Linux — edit `/etc/docker/daemon.json`:
> ```json
> {
>   "insecure-registries": ["192.168.2.128:8082"]
> }
> ```
> Then restart Docker: `sudo systemctl restart docker`
>
> On each Kubernetes **worker node**, also configure containerd to allow the insecure registry by editing `/etc/containerd/config.toml` and restarting containerd.

---

## Deploy to Kubernetes

```bash
# Apply all manifests
kubectl apply -f k8s-deployment.yaml

# Verify namespace
kubectl get ns maximuslabog

# Watch pods come up
kubectl get pods -n maximuslabog -w

# Check service and ingress
kubectl get svc,ingress -n maximuslabog
```

---

## DNS / Hosts Configuration

The Ingress is configured for host: **`maximuslabog.lab.local`**

Add this entry to `/etc/hosts` on any machine that needs to access the site (or configure it in your local DNS / Pi-hole / pfSense):

```
<ingress-controller-IP>   maximuslabog.lab.local
```

To find your ingress controller's external IP:
```bash
kubectl get svc -n ingress-nginx
# Look for the EXTERNAL-IP of the ingress-nginx-controller service
```

Then open: **`http://maximuslabog.lab.local`**

---

## Quick Test (No DNS Required)

```bash
kubectl port-forward -n maximuslabog svc/maximuslabog-web 8080:80
```
Then open: `http://localhost:8080`

---

## Resource Limits

| | CPU | Memory |
|---|---|---|
| Request | `50m` | `64Mi` |
| Limit | `200m` | `128Mi` |

---

## Health Probes

| Probe | Path | Port | Initial Delay | Period |
|---|---|---|---|---|
| Liveness | `/healthz` | `80` | `10s` | `30s` |
| Readiness | `/healthz` | `80` | `5s` | `10s` |

The `/healthz` endpoint is handled by Nginx and returns `200 OK`.

---

## Rollout Strategy

```yaml
type: RollingUpdate
maxSurge: 1
maxUnavailable: 0
```

Zero downtime deploys — new pods are created before old ones are removed.

---

## Kubernetes Commands Reference

| Action | Command |
|---|---|
| Apply manifests | `kubectl apply -f k8s-deployment.yaml` |
| Get pods | `kubectl get pods -n maximuslabog` |
| Get all resources | `kubectl get all -n maximuslabog` |
| View pod logs | `kubectl logs -n maximuslabog deploy/maximuslabog-web` |
| Describe deployment | `kubectl describe deploy maximuslabog-web -n maximuslabog` |
| Restart (re-pull image) | `kubectl rollout restart deploy/maximuslabog-web -n maximuslabog` |
| Watch rollout | `kubectl rollout status deploy/maximuslabog-web -n maximuslabog` |
| Scale replicas | `kubectl scale deploy maximuslabog-web -n maximuslabog --replicas=3` |
| Delete everything | `kubectl delete namespace maximuslabog` |

---

## Updating to a New Version

```bash
# 1. Build and push new image with new tag
docker build -t maximuslabog-web:v2 .
docker tag maximuslabog-web:v2 192.168.2.128:8082/maximuslabog-web:v2
docker push 192.168.2.128:8082/maximuslabog-web:v2

# 2. Update the image in your deployment
kubectl set image deploy/maximuslabog-web \
  maximuslabog-web=192.168.2.128:8082/maximuslabog-web:v2 \
  -n maximuslabog

# 3. Watch the rolling update
kubectl rollout status deploy/maximuslabog-web -n maximuslabog
```

---

## TLS / HTTPS (Optional)

To enable HTTPS with cert-manager, add annotations and a TLS block to the Ingress:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  tls:
    - hosts:
        - maximuslabog.lab.local
      secretName: maximuslabog-tls
  rules:
    - host: maximuslabog.lab.local
      ...
```

---

© 2025 MaximusLab. Home lab. Real stakes. OG time.