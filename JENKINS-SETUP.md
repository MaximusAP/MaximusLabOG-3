# MaximusLab OG Jenkins Pipeline Setup

## Jenkins credentials

Create these global credentials:

1. `nexus-docker-credentials`
   - Type: Username with password
   - Nexus account with push/pull access

2. `kubeconfig-lab`
   - Type: Secret file
   - Upload a kubeconfig that points to the Kubernetes API VIP and is reachable from the Jenkins agent

## Jenkins agent requirements

The node with label `docker-slave` must provide:

```bash
docker --version
kubectl version --client
curl --version
git --version
docker ps
```

## Jenkins Pipeline job

- New Item: `MaximusLabOG-K8s-Deploy`
- Type: Pipeline
- Definition: Pipeline script from SCM
- SCM: Git
- Repository: `https://github.com/MaximusAP/MaximusLabOG.git`
- Branch: `*/master` or `*/main`
- Script path: `Jenkinsfile`

## Docker HTTP registry on jenkins-02

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "insecure-registries": ["192.168.2.128:8082"]
}
JSON
sudo systemctl restart docker
sudo docker info | grep -A5 'Insecure Registries'
```

## Kubernetes node registry configuration

Each node must contain:

`/etc/containerd/certs.d/192.168.2.128:8082/hosts.toml`

```toml
server = "http://192.168.2.128:8082"

[host."http://192.168.2.128:8082"]
  capabilities = ["pull", "resolve"]
```

Then restart containerd:

```bash
sudo systemctl restart containerd
```

## Manual verification

```bash
kubectl get all -n maximuslabog
kubectl get ingress -n maximuslabog
kubectl rollout status deployment/maximuslabog-web -n maximuslabog
curl http://maximuslabog.lab.local/healthz
```
