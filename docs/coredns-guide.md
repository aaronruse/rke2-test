# CoreDNS Setup & Public Ingress/Egress Guide

This document explains the DNS architecture for your RKE2 cluster and provides
step-by-step instructions for exposing workload applications to the internet.

---

## Architecture Overview

```
Internet
    │
    │  (DNS: *.yourdomain.com → app_nlb_public_ip)
    ▼
AWS Application NLB (Elastic IP — stable public address)
    │  Port 80/443
    ▼
Worker Nodes ASG (t3.xlarge × 4)
    │  NodePort 80/443
    ▼
ingress-nginx (DaemonSet/Deployment on workers)
    │  Reads Ingress resources
    ▼
Kubernetes Services → Pods
    │
    ▼
CoreDNS (cluster.local DNS — internal service discovery)
```

The cluster uses two DNS layers:
- **External DNS**: Your public domain (`*.yourdomain.com`) resolved via Route 53 or your DNS provider, pointing to the NLB's Elastic IP.
- **Internal DNS**: CoreDNS at `10.96.0.10` resolves `svc.cluster.local` names inside the cluster.

---

## Step 1 — Get Your NLB Public IP

After `terraform apply`, retrieve the application NLB's Elastic IP:

```bash
terraform output app_nlb_public_ip
# Example output: 54.198.12.34
```

This IP is **static** — it will not change even if the NLB is modified. Use it for all DNS records.

---

## Step 2 — Configure Public DNS (Route 53 or External Provider)

### Option A: AWS Route 53

```bash
# Replace HOSTED_ZONE_ID with your Route 53 hosted zone ID
# Replace 54.198.12.34 with your actual app_nlb_public_ip

HOSTED_ZONE_ID="Z1234567890ABC"
NLB_IP="54.198.12.34"
DOMAIN="yourdomain.com"

# Wildcard A record — all apps under *.yourdomain.com resolve to the NLB
aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"*.${DOMAIN}\",
        \"Type\": \"A\",
        \"TTL\": 300,
        \"ResourceRecords\": [{\"Value\": \"${NLB_IP}\"}]
      }
    }]
  }"
```

For production, use a CNAME pointing to the NLB DNS name instead of the IP:
```bash
terraform output app_nlb_dns
# Use this as CNAME target for lower TTLs and AWS-managed failover
```

### Option B: Any DNS Provider

Create an **A record**:
```
Type:  A
Name:  *.yourdomain.com   (or app.yourdomain.com for a single app)
Value: <app_nlb_public_ip>
TTL:   300
```

---

## Step 3 — CoreDNS Internal DNS Verification

CoreDNS is deployed at `10.96.0.10` (the 10th IP in your 10.96.0.0/12 service CIDR).

### Verify CoreDNS is Running

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get svc kube-dns -n kube-system
```

Expected output for the service:
```
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)         AGE
kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP   5m
```

### Test Internal DNS Resolution

```bash
# Spin up a test pod
kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -it -- \
  nslookup kubernetes.default.svc.cluster.local

# Expected: resolves to 10.96.0.1 (kubernetes service IP)

# Test a specific service you deployed
kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -it -- \
  nslookup <your-service-name>.<namespace>.svc.cluster.local
```

### View the Live Corefile

```bash
kubectl get configmap coredns -n kube-system -o yaml
```

### Add a Custom DNS Stub Zone (e.g. for on-prem resolution)

Edit the CoreDNS ConfigMap to add a stub zone:

```bash
kubectl edit configmap coredns -n kube-system
```

Add under the `.:53` block:

```
stub_zone.internal:53 {
    forward . 192.168.1.53
    cache 30
}
```

Then restart CoreDNS:
```bash
kubectl rollout restart deployment/coredns -n kube-system
```

---

## Step 4 — Deploy Your Application with an Ingress Resource

This is the standard pattern to expose any application through the NLB → ingress-nginx → pod path.

### 4a. Create a Namespace, Deployment, and Service

```yaml
# app.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      # Pin to worker nodes
      nodeSelector:
        node-role.kubernetes.io/worker: "true"
      containers:
        - name: my-app
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: my-app
spec:
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f app.yaml
```

### 4b. Create an Ingress Resource (HTTP)

```yaml
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-app
  annotations:
    kubernetes.io/ingress.class: "nginx"
spec:
  rules:
    - host: my-app.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

```bash
kubectl apply -f ingress.yaml
```

### 4c. Create an Ingress with TLS (HTTPS via Let's Encrypt)

Prerequisite: cert-manager deployed and ClusterIssuer created (run `helm/deploy.sh` with `ACME_EMAIL` set).

```yaml
# ingress-tls.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-tls
  namespace: my-app
  annotations:
    kubernetes.io/ingress.class: "nginx"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  tls:
    - hosts:
        - my-app.yourdomain.com
      secretName: my-app-tls-cert
  rules:
    - host: my-app.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

```bash
kubectl apply -f ingress-tls.yaml

# Watch cert-manager issue the certificate (~60s for staging, ~2min for prod):
kubectl get certificate -n my-app -w
kubectl describe certificate my-app-tls-cert -n my-app
```

---

## Step 5 — Verify End-to-End Connectivity

```bash
# DNS resolution from outside the cluster
nslookup my-app.yourdomain.com
# Should return: app_nlb_public_ip

# HTTP connectivity
curl -v http://my-app.yourdomain.com

# HTTPS connectivity (after cert issued)
curl -v https://my-app.yourdomain.com

# Check ingress is registered
kubectl get ingress -n my-app

# Check ingress-nginx is routing correctly
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50
```

---

## CoreDNS Configuration Details

### Service CIDR and DNS IP Mapping

| Setting        | Value            | Notes                              |
|----------------|------------------|------------------------------------|
| `service-cidr` | `10.96.0.0/12`   | Set in RKE2 server config          |
| CoreDNS IP     | `10.96.0.10`     | 10th address in service CIDR       |
| Kubernetes SVC | `10.96.0.1`      | 1st address — kubernetes API svc   |

### Pod CIDR Note

Your pod CIDR is `169.254.0.0/16` (link-local). CoreDNS reverse DNS lookups
for pod IPs (`ip6.arpa` / `in-addr.arpa`) may behave unexpectedly with this
range on some OS network stacks since 169.254.x.x is typically reserved.
Standard alternative: `10.42.0.0/16`. Monitor for any DNS reverse-lookup issues.

### Useful CoreDNS Diagnostic Commands

```bash
# View CoreDNS logs live
kubectl logs -n kube-system -l k8s-app=kube-dns -f

# Check CoreDNS metrics (if Prometheus is deployed)
kubectl port-forward -n kube-system svc/kube-dns 9153:9153
curl http://localhost:9153/metrics | grep coredns

# Force a CoreDNS reload after ConfigMap changes
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system
```

---

## Egress from Pods

All worker and control plane pods egress to the internet via the **NAT Gateway**.
The NAT Gateway's public IP is available via:

```bash
terraform output nat_gateway_public_ip
```

If your applications need to whitelist an egress IP (e.g. for third-party API calls),
use this IP. It is stable (backed by an EIP).

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| DNS not resolving inside cluster | CoreDNS pod not running | `kubectl get pods -n kube-system -l k8s-app=kube-dns` |
| `curl` to app times out | NLB target group unhealthy | Check worker SG allows port 80/443; verify ingress-nginx pods are running |
| cert-manager stuck | ACME HTTP-01 challenge failing | Ensure port 80 is reachable; check `kubectl describe challenge` |
| Workers show NotReady | Canal/VXLAN blocked | Verify SG allows UDP 8472 within VPC CIDR |
| SSH to control plane fails | Bastion not started or EIP not attached | Check `terraform output bastion_public_ip`; verify SG allows SSH |
