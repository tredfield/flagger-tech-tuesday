# README.md

This project demonstrates using <https://flagger.app/> to perform canary deployments

You will perform the following:

1. Setup a local kubernetes cluster using kind
1. Install nginx, prometheus, grafana, and flagger
1. Install test application `podinfo`
1. Create a canary resource
1. Perform a canary deployment using flagger

## Local Kubernetes Cluster

Create a disposable k8s cluster on local machine for faster infrastructure and application experiments than relying on centrally managed clusters.

After installing the pre-requisites, simply run `./start.sh` to create a new k8s cluster named `k8s-local` on local machine. In the cluster, it will install [prometheus](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) integrated with [grafana](https://grafana.com/docs/grafana/latest/datasources/prometheus/query-editor/), [nginx ingress](https://github.com/kubernetes/ingress-nginx/tree/main/charts/ingress-nginx), [flagger](https://docs.flagger.app/tutorials/nginx-progressive-delivery) and its [load tester tool](https://docs.flagger.app/tutorials/nginx-progressive-delivery#bootstrap).

## Pre-requisites

To set up a disposable cluster locally, ensure that below pre-requisites are installed on the local machine.

- [Docker](https://docs.docker.com/get-docker/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installing-with-a-package-manager)
- [Helm](https://helm.sh/docs/intro/install/)

Ensure that ports 80, 443, 3000, 9090 and 9093 are free. If not, please see [Port Mapping](#port-mapping) section below.

## Provision cluster and components

Ensure that docker is running.

**Run `./start.sh`**

Alternatively use the `start.sh` and run commands manually

1. Verify the installation by running `kubectl get pods,svc,ing,cm,secret -A`

1. **Prometheus UI: <http://localhost:9090>** (Internally within the cluster, Prometheus service is available at: <http://prometheus-prometheus.monitoring:9090>)

1. **Grafana UI: <http://localhost:3000>** (Use `admin` : `prom-operator` default local login)

1. **Alert Manager UI: <http://localhost:9093>**

## Deploy the test application

1. Create namespace test

    ```bash
    kubectl create ns test
    ```

1. Deploy podinfo

    ```bash
    kubectl -n test apply -k github.com/stefanprodan/podinfo//kustomize
    ```

1. Deploy the load testing service to generate traffic during the canary analysis:

    ```bash
    helm upgrade -i flagger-loadtester flagger/loadtester --namespace=test
    ```

1. Create an ingress definition:

    ```yaml
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: podinfo
      namespace: test
      labels:
        app: podinfo
      annotations:
        kubernetes.io/ingress.class: "nginx"
    spec:
      rules:
        - host: "app.example.com"
          http:
            paths:
              - pathType: Prefix
                path: "/"
                backend:
                  service:
                    name: podinfo
                    port:
                      number: 9898
    ```

    Save the above resource as podinfo-ingress.yaml and then apply it:

    ```bash
    kubectl apply -f ./podinfo-ingress.yaml
    ```

1. Add host entry to the hosts file:

    ```bash
    ipconfig getifaddr en0
    # Add the below line to /etc/hosts with the IP address from command above
    # 127.0.0.1   app.example.com
    ```

    - *nix hosts file available at _/etc/hosts_
    - Windows hosts file available at _C:\Windows\System32\Drivers\etc\hosts_
    - Above example, assumes the `host` in ingress object is app.example.com_
    - You may need the IP address of your machine for proper DNS resolution for `curl` `hey` and such commands when they run inside Kubernetes. You can find it by running `ipconfig getifaddr en0` or similar. Substitute `127.0.0.1` with the machine IP address.

1. Access the app at <http://app.example.com> . Verify from command line by running `curl http://app.example.com` . You can install the [hey tool](https://github.com/rakyll/hey) and throw some traffic at the app using the command `hey -z 30s -q 15 -c 2 http://app.example.com` . This command will simulate 2 concurrent users sending 15 queries per second for 30 seconds. It is useful to view graphs in Prometheus and Grafana.

## Create a canary resource

1. Create a canary custom resource

    ```yaml
    apiVersion: flagger.app/v1beta1
    kind: Canary
    metadata:
      name: podinfo
      namespace: test
    spec:
      provider: nginx
      # deployment reference
      targetRef:
        apiVersion: apps/v1
        kind: Deployment
        name: podinfo
      # ingress reference
      ingressRef:
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        name: podinfo
      # HPA reference (optional)
      autoscalerRef:
        apiVersion: autoscaling/v2beta2
        kind: HorizontalPodAutoscaler
        name: podinfo
      # the maximum time in seconds for the canary deployment
      # to make progress before it is rollback (default 600s)
      progressDeadlineSeconds: 600
      service:
        # ClusterIP port number
        port: 9898
        # container port number or name
        targetPort: 9898
      analysis:
        # schedule interval (default 60s)
        interval: 10s
        # max number of failed metric checks before rollback
        threshold: 10
        # max traffic percentage routed to canary
        # percentage (0-100)
        maxWeight: 100
        # canary increment step
        # percentage (0-100)
        stepWeight: 5
        # NGINX Prometheus checks
        metrics:
        - name: request-success-rate
          # minimum req success rate (non 5xx responses)
          # percentage (0-100)
          thresholdRange:
            min: 99
          interval: 1m
        # testing (optional)
        webhooks:
          - name: acceptance-test
            type: pre-rollout
            url: http://flagger-loadtester.test/
            timeout: 30s
            metadata:
              type: bash
              cmd: "curl -sd 'test' http://podinfo-canary:9898/token | grep token"
          - name: load-test
            url: http://flagger-loadtester.test/
            timeout: 5s
            metadata:
              cmd: "hey -z 1m -q 10 -c 2 http://app.example.com/"
    ```

    Save the above resource as podinfo-canary.yaml and then apply it:

    ```bash
    kubectl apply -f ./podinfo-canary.yaml
    ```

1. Trigger a canary deployment by updating the container image:

    ```bash
    kubectl -n test set image deployment/podinfo podinfod=ghcr.io/stefanprodan/podinfo:6.0.1
    ```

    Flagger detects that the deployment revision changed and starts a new rollout:

    ```bash
    kubectl -n test describe canary/podinfo
    ```

## Tear down the local cluster

```bash
kind delete cluster --name=k8s-local
```

It will delete the local kind cluster

## Monitoring k8s and app deployments

1. Prometheus

    1. you may observe metrics in [prometheus at http://localhost:9090](http://localhost:9090) yourself.
  
    1. Sample query:

        ```sh
        sum by (canary, status) (
          rate(
            nginx_ingress_controller_requests{
              namespace="test",
              ingress="podinfo"
            }[1m]
          )
        )
        ```

    1. Select `Graph` and go to date and time near the deployment time. Remember to check `Use Local Time` box.

1. Grafana

   You may observe metric in [Grafana at http://localhost:3000](http://localhost:3000/dashboards?tag=nginx). Local grafana has default login as `admin` and [`prom-operator`](https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/values.yaml#L737).

   The preconfigured [nginx-ingress-controller](http://localhost:3000/d/nginx/nginx-ingress-controller?orgId=1&refresh=5s) is a useful dashboard to view.

## FAQ

1. Why is cluster startup so slow?

    In addition to Kind cluster, we also install prometheus, grafana, nginx ingress controller and flagger etc. All of them require image pulls from the internet. About 500MB of images are pulled. It takes ~5 minutes on my machine. Your experience may vary. To mitigate slow network impact and repeated bandwidth consumption from ephemeral cluster creation and deletion, we have added local image registries and pointed kind config to look their first. After the first time, startup should be faster as long as docker stays running between kind teardown and startup.

1. Port Mapping

    I am unable to free up default ports. How can I map different ports?

    We are enabling [hostPort](https://github.com/kubernetes/ingress-nginx/blob/main/charts/ingress-nginx/values.yaml#L93). We are routing ports 80, 443, 3000, 9090 and 9093 to Kind K8s. If you cannot free up these ports, please modify [kind-config-local.yaml](kind-config-local.yaml) with your free port numbers as follows:

    In [kind-config-local.yaml](kind-config-local.yaml):

    ```yaml
        extraPortMappings:
        - containerPort: 80
          hostPort: <<desired http port>>
          protocol: TCP
        - containerPort: 443
          hostPort: <<desired https port>>
          protocol: TCP
        - containerPort: 9090
          hostPort: <<desired prometheus port>>
          protocol: TCP
        - containerPort: 3000
          hostPort: <<desired grafana port>>
          protocol: TCP
        - containerPort: 9093
          hostPort: <<desired alert manager port>>
          protocol: TCP
    ```

1. Why 1 minute is the minimum recommended look-back interval for metrics analysis?

    Because [by default](https://github.com/kubernetes/ingress-nginx/blob/main/charts/ingress-nginx/values.yaml#L728), Nginx Service Monitor for Prometheus is set to scrape nginx metrics every 30 secs. 1 minute interval will capture at least one scrape. For faster local development, we have reduced the scrape interval to 10 seconds. See `serviceMonitor.scrapeInterval="10s"` in [start.sh](./start.sh).

1. How do I interpret the times shown in logs and UIs?

    Some logs and UI show time in UTC (GMT). Subtract 8 hours for PST (7 hours for PDT).

    [https://www.worldtimebuddy.com/](https://www.worldtimebuddy.com/pdt-to-utc-converter)

## References

1. [Kind Quick Start - Mapping ports to the host machine](https://kind.sigs.k8s.io/docs/user/quick-start/#mapping-ports-to-the-host-machine)
1. [NGINX Ingress Controller - Exposing TCP and UDP services](https://kubernetes.github.io/ingress-nginx/user-guide/exposing-tcp-udp-services/)
1. [Flagger Canary Spec](https://github.com/fluxcd/flagger/blob/main/artifacts/flagger/crd.yaml#L857)
1. [helm-charts/charts/kube-prometheus-stack/values.yaml](https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/values.yaml)
1. [ingress-nginx/charts/ingress-nginx/values.yaml](https://github.com/kubernetes/ingress-nginx/blob/main/charts/ingress-nginx/values.yaml)
1. [kubernetes ingress-nginx Monitoring Installation Tutorial](https://github.com/kubernetes/ingress-nginx/blob/main/docs/user-guide/monitoring.md)
1. [Adding persistent grafana dashboards](https://stackoverflow.com/questions/57322022/stable-prometheus-operator-adding-persistent-grafana-dashboards)
1. [Pull-through Docker registry on Kind clusters](https://maelvls.dev/docker-proxy-registry-kind/)
1. [Talos Linux Guides - Pull Through Image Cache](https://www.talos.dev/v1.2/talos-guides/configuration/pull-through-cache/#launch-the-caching-docker-registry-proxies)
1. [kubernetes-sigs kind GitHub Issue - Cache Docker images #1591](https://github.com/kubernetes-sigs/kind/issues/1591)
1. [Google Cloud - Pulling cached Docker Hub images](https://cloud.google.com/container-registry/docs/pulling-cached-images#docker-ui)
