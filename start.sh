#!/bin/sh
set -o errexit

export PROMETHEUS_PORT=9090
export GRAFANA_PORT=3000
export ALERTMANAGER_PORT=9093
export KIND_CLUSTER_NAME=k8s-local

start=$(date +%s)

# Create local kind cluster
kind create cluster --name=$KIND_CLUSTER_NAME --config=kind-config-local.yaml

# Verify cluster install
kubectl cluster-info --context kind-$KIND_CLUSTER_NAME
export KIND_IP=$(docker container inspect $KIND_CLUSTER_NAME-control-plane   --format '{{ .NetworkSettings.Networks.kind.IPAddress }}')

echo "[$((($(date +%s))-$start))s] Kind cluster created with IP: $KIND_IP"

# Local pull-through cache of docker images
docker start registry-docker.io || docker run -d \
    -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
    --restart always --net=kind \
    --name registry-docker.io registry:2

docker start registry-k8s.gcr.io || docker run -d \
    -e REGISTRY_PROXY_REMOTEURL=https://k8s.gcr.io \
    --restart always --net=kind \
    --name registry-k8s.gcr.io registry:2

docker start registry-quay.io || docker run -d \
    -e REGISTRY_PROXY_REMOTEURL=https://quay.io \
    --restart always --net=kind \
    --name registry-quay.io registry:2.5

docker start registry-gcr.io || docker run -d \
    -e REGISTRY_PROXY_REMOTEURL=https://gcr.io \
    --restart always --net=kind \
    --name registry-gcr.io registry:2

docker start registry-ghcr.io || docker run -d \
    -e REGISTRY_PROXY_REMOTEURL=https://ghcr.io \
    --restart always --net=kind \
    --name registry-ghcr.io registry:2

docker start registry-registry.k8s.io || docker run -d \
    -e REGISTRY_PROXY_REMOTEURL=https://registry.k8s.io \
    --restart always --net=kind \
    --name registry-registry.k8s.io registry:2

echo "[$((($(date +%s))-$start))s] Local docker image registries installed for various domains"

# Install Prometheus
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set fullnameOverride=prometheus

echo "[$((($(date +%s))-$start))s] kube-prometheus-stack installed"

# Install nginx ingress along with localhost TCP routing for prometheus
# See: https://github.com/kubernetes/ingress-nginx/blob/main/docs/user-guide/exposing-tcp-udp-services.md for rationale
# and https://github.com/kubernetes/ingress-nginx/blob/main/charts/ingress-nginx/values.yaml for nginx values to set
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostPort.enabled=true \
  --set controller.metrics.enabled=true \
  --set-string controller.podAnnotations."prometheus\.io/scrape"="true" \
  --set-string controller.podAnnotations."prometheus\.io/port"="10254" \
  --set controller.metrics.serviceMonitor.enabled=true \
  --set controller.metrics.serviceMonitor.additionalLabels.release="prometheus" \
  --set controller.metrics.serviceMonitor.honorLabels="true" \
  --set-string tcp."$PROMETHEUS_PORT"="monitoring/prometheus-prometheus:9090" \
  --set-string tcp."$GRAFANA_PORT"="monitoring/prometheus-grafana:80" \
  --set-string tcp."$ALERTMANAGER_PORT"="monitoring/prometheus-alertmanager:9093" 

echo "[$((($(date +%s))-$start))s] ingress-nginx installed"

# Wait for prometheus to be ready
kubectl wait --namespace monitoring \
  --for=condition=ready pod \
  --selector=release=prometheus \
  --timeout=120s

# Verify prometheus config
helm get values prometheus --namespace monitoring
kubectl --namespace monitoring get pods -l "release=prometheus"

echo "[$((($(date +%s))-$start))s] kube-prometheus-stack ready"

# Wait for nginx controller to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

# Verify nginx ingress config
helm get values ingress-nginx --namespace ingress-nginx
kubectl --namespace ingress-nginx get services ingress-nginx-controller -o wide 

echo "[$((($(date +%s))-$start))s] ingress-nginx ready"

# Install Flagger
helm repo add flagger https://flagger.app
helm upgrade -i flagger flagger/flagger \
  --namespace flagger-system --create-namespace \
  --set metricsServer=http://prometheus-prometheus.monitoring:9090 \
  --set meshProvider=nginx \
  --set clusterName=$KIND_CLUSTER_NAME

echo "[$((($(date +%s))-$start))s] flagger installed"

# Install Flagger test load creator
helm upgrade -i flagger-loadtester flagger/loadtester \
  --namespace flagger-system

echo "[$((($(date +%s))-$start))s] flagger-loadtester installed"

# Wait for flagger to be ready
kubectl wait --namespace flagger-system \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=flagger \
  --timeout=60s

echo "[$((($(date +%s))-$start))s] flagger ready"

kubectl wait --namespace flagger-system \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=loadtester \
  --timeout=60s

echo "[$((($(date +%s))-$start))s] flagger-loadtester ready"

# Install Grafana dashboard configmaps for nginx
wget -nv https://github.com/kubernetes/ingress-nginx/raw/main/deploy/grafana/dashboards/nginx.json -O nginx.json
kubectl -n monitoring create cm grafana-nginx-ingress-controller --from-file=nginx.json --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring label cm grafana-nginx-ingress-controller grafana_dashboard=1 --dry-run=client -o yaml | kubectl apply -f -

wget -nv https://github.com/kubernetes/ingress-nginx/raw/main/deploy/grafana/dashboards/request-handling-performance.json -O request-handling-performance.json
kubectl -n monitoring create cm grafana-nginx-request-handling-performance --from-file=request-handling-performance.json --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring label cm grafana-nginx-request-handling-performance grafana_dashboard=1 --dry-run=client -o yaml | kubectl apply -f -

echo "[$((($(date +%s))-$start))s] nginx grafana dashboards installed as configmaps"

# Print cluster info
echo "Pods installed:"
kubectl get pods -A
echo "Docker images installed:"
docker exec -it $KIND_CLUSTER_NAME-control-plane crictl images
echo "Docker image cache size by registry:"
echo "docker.io: $(docker exec -it registry-docker.io du -sh  /var/lib/registry/docker/registry/v2/ || true)"
echo "k8s.gcr.io: $(docker exec -it registry-k8s.gcr.io du -sh  /var/lib/registry/docker/registry/v2/|| true)"
echo "quay.io: $(docker exec -it registry-quay.io du -sh  /var/lib/registry/docker/registry/v2/ || true)"
echo "gcr.io: $(docker exec -it registry-gcr.io du -sh  /var/lib/registry/docker/registry/v2/|| true)"
echo "ghcr.io: $(docker exec -it registry-ghcr.io du -sh  /var/lib/registry/docker/registry/v2/ || true)"
echo "registry.k8s.io: $(docker exec -it registry-registry.k8s.io du -sh  /var/lib/registry/docker/registry/v2/ || true)"

echo "[$((($(date +%s))-$start))s] Kubernetes stack up and running"
