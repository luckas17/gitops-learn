# GitOps Lab - Troubleshooting Notes

## Issues & Solutions

### 1. httpbin Pod CrashLoopBackOff
**Issue:** Pod crash dengan error `gunicorn could not be found`

**Root Cause:**
- Custom command di deployment: `pipenv run gunicorn -b 0.0.0.0:8080 httpbin:app -k gevent`
- Image `kong/httpbin` tidak punya gunicorn di pipenv environment

**Solution:**
1. Ganti image ke `kennethreitz/httpbin`
2. Hapus custom command (pakai default entrypoint)
3. Update containerPort dari 8080 ke 80
4. Update service targetPort dari 8080 ke 80

**Commands:**
```bash
kubectl set image deployment/httpbin httpbin=kennethreitz/httpbin
kubectl patch deployment httpbin --type json -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/command"}]'
kubectl patch deployment httpbin --type json -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/ports/0/containerPort", "value": 80}]'
kubectl patch svc httpbin --type json -p='[{"op": "replace", "path": "/spec/ports/0/targetPort", "value": 80}]'
```

---

### 2. argocd-repo-server Liveness Probe Timeout
**Issue:** Pod restart terus karena liveness probe failed dengan `context deadline exceeded`

**Root Cause:**
- Health check timeout terlalu pendek (1s)
- Repo server butuh waktu lebih lama untuk respond

**Solution:**
Perpanjang liveness probe timeout dan initial delay:
```bash
kubectl patch deployment argocd-repo-server -n argocd --type json -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/timeoutSeconds", "value": 10},
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds", "value": 30}
]'
```

---

### 3. Kiali Pod CrashLoopBackOff
**Issue:** Pod crash dengan liveness probe failed - connection refused ke port 20001

**Root Cause:**
1. RBAC permissions kurang untuk `telemetries.telemetry.istio.io` dan `wasmplugins.extensions.istio.io`
2. Kiali stuck di "Waiting for cluster-scoped cache to sync"
3. Liveness probe initialDelay terlalu pendek (5s)

**Solution:**
1. Tambah RBAC untuk telemetry & extensions API groups:
```yaml
- apiGroups:
  - networking.istio.io
  - security.istio.io
  - telemetry.istio.io
  - extensions.istio.io
  resources: ["*"]
  verbs:
  - get
  - list
  - watch
```

2. Perpanjang liveness probe initialDelay dari 5s ke 30s

3. Fix health probe path dari `/kiali/healthz` ke `/healthz`
   - Kiali v1.89 serve health endpoint di root path, bukan `/kiali` prefix

**Apply:**
```bash
kubectl apply -f observability/kiali/kiali.yaml
kubectl delete pods -n istio-system -l app=kiali
```

**Status:** ✅ **RESOLVED** - Kiali running successfully

---

### 4. ArgoCD Application Namespace Mismatch
**Issue:** Kiali & Jaeger OutOfSync dengan error `namespaces "observability" not found`

**Root Cause:**
- ArgoCD Application destination namespace: `observability`
- Seharusnya: `istio-system`
- ClusterRole & ClusterRoleBinding tidak punya namespace (cluster-scoped) tapi ArgoCD coba apply ke namespace observability

**Solution:**
```bash
kubectl patch application observability-kiali -n argocd --type merge -p '{"spec":{"destination":{"namespace":"istio-system"}}}'
kubectl patch application observability-jaeger -n argocd --type merge -p '{"spec":{"destination":{"namespace":"istio-system"}}}'
```

---

### 5. Istio Gateway Invalid Spec
**Issue:** Gateway resource invalid dengan error `spec.servers[0].port.name: Required value`

**Root Cause:**
Port definition kurang field `name`

**Solution:**
```yaml
servers:
  - port:
      number: 80
      name: http        # Required!
      protocol: HTTP
    hosts:
      - "*"
```

---

## Testing Results

### Internal Communication (Service Mesh)
✅ **Working:** sleep → httpbin communication via mTLS
```bash
kubectl exec deploy/sleep -- curl -s httpbin:8000/get
```

**Evidence of mTLS:**
- Header `X-Forwarded-Client-Cert` present
- Contains SPIFFE identity: `spiffe://cluster.local/ns/default/sa/sleep`

### External Access
⚠️ **Pending:** Istio Ingress Gateway pod belum terinstall
- Gateway resource: ✅ Created
- VirtualService: ✅ Created
- Ingress Gateway Pod: ❌ Not installed

---

## Key Learnings

1. **Custom commands** di deployment harus match dengan image capabilities
2. **Liveness probe** perlu disesuaikan dengan startup time aplikasi
3. **RBAC** harus lengkap untuk semua API groups yang diakses aplikasi
4. **ArgoCD namespace** harus match dengan resource target namespace
5. **Istio Gateway** butuh pod ingress gateway untuk handle external traffic
6. **GitOps workflow:** Commit → Push → ArgoCD Sync (atau manual apply untuk quick fix)

---

## Architecture

```
Internet (pending ingress gateway)
    ↓
[Istio Ingress Gateway Pod] ← Not installed yet
    ↓
Gateway Resource (httpbin-gw) ✅
    ↓
VirtualService (httpbin) ✅
    ↓
Service (httpbin:8000 → 80) ✅
    ↓
Pod httpbin (with istio-proxy sidecar) ✅
    ↑
Pod sleep (with istio-proxy sidecar) ✅
```

**Observability Stack:**
- Kiali: ✅ Running (fixed RBAC + health probe path)
- Jaeger: ✅ Running
- ArgoCD: ✅ Running

---

---

## Istio Service Mesh - Use Cases Implementation

### Setup Overview
- **Namespace:** workload
- **Services:** httpbin (v1 & v2), sleep
- **Istio Injection:** ✅ Enabled
- **Sidecar Proxy:** ✅ Running on all pods

### 1. Security - mTLS (Mutual TLS)
**Status:** ✅ Active (default)

**What it does:**
- Automatic encryption between services
- Mutual authentication using SPIFFE identities
- No code changes needed

**Verification:**
```bash
kubectl exec -n workload deploy/sleep -- curl -s http://httpbin:8000/headers | grep X-Forwarded-Client-Cert
```

**Evidence:**
```
X-Forwarded-Client-Cert: By=spiffe://cluster.local/ns/workload/sa/httpbin;
URI=spiffe://cluster.local/ns/workload/sa/sleep
```

---

### 2. Traffic Management - Canary Deployment
**Status:** ✅ Implemented (80% v1, 20% v2)

**What it does:**
- Gradual rollout of new version
- Split traffic by percentage
- Easy rollback if issues

**Configuration:**
```yaml
# VirtualService
http:
  - route:
      - destination:
          host: httpbin
          subset: v1
        weight: 80
      - destination:
          host: httpbin
          subset: v2
        weight: 20
```

**Testing:**
```bash
for i in {1..50}; do kubectl exec -n workload deploy/sleep -- curl -s http://httpbin:8000/ip; done
```

**View in Kiali:** Graph shows traffic split between v1 and v2

---

### 3. Resilience - Retry & Timeout
**Status:** ✅ Configured

**What it does:**
- Auto retry on failures (5xx, connection errors)
- Prevent hanging requests with timeout
- Improve reliability without code changes

**Configuration:**
```yaml
# VirtualService
http:
  - route: [...]
    timeout: 10s
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx,reset,connect-failure
```

**Behavior:**
- Max 10s total timeout per request
- Retry up to 3 times on errors
- Each retry max 2s

---

### 4. Resilience - Circuit Breaker
**Status:** ✅ Configured

**What it does:**
- Limit connections to prevent overload
- Eject unhealthy pods automatically
- Fail fast instead of cascading failures

**Configuration:**
```yaml
# DestinationRule
trafficPolicy:
  connectionPool:
    tcp:
      maxConnections: 10
    http:
      http1MaxPendingRequests: 10
      maxRequestsPerConnection: 2
  outlierDetection:
    consecutiveErrors: 3
    interval: 30s
    baseEjectionTime: 30s
    maxEjectionPercent: 100
```

**Behavior:**
- Max 10 concurrent connections
- If pod fails 3 times → ejected for 30s
- Prevents overwhelming failing pods

---

### 5. Testing - Fault Injection
**Status:** ✅ Configured (optional, for chaos testing)

**What it does:**
- Inject delays to test timeout handling
- Inject errors to test retry logic
- Test resilience without breaking actual services

**Configuration:**
```yaml
# VirtualService (httpbin-fault.yaml)
http:
  - fault:
      delay:
        percentage:
          value: 10
        fixedDelay: 5s
      abort:
        percentage:
          value: 5
        httpStatus: 500
    route: [...]
```

**Behavior:**
- 10% requests delayed by 5s
- 5% requests return HTTP 500
- Use for testing, not production

---

### 6. Observability - Automatic Metrics & Tracing
**Status:** ✅ Active

**What it does:**
- Automatic metrics collection (latency, error rate, throughput)
- Distributed tracing across services
- Service graph visualization

**Tools:**
- **Kiali:** Service mesh graph, traffic flow
- **Jaeger:** Distributed tracing
- **Prometheus:** Metrics storage

**Access:**
```bash
# Kiali
kubectl port-forward -n istio-system svc/kiali 20001:20001
# Open: http://localhost:20001

# Jaeger
kubectl port-forward -n istio-system svc/jaeger-query 16686:16686
# Open: http://localhost:16686
```

---

### Istio Components Explained

**Gateway** = Entry point from outside cluster
- Opens ports (80, 443)
- Handles TLS termination
- Like nginx/load balancer

**VirtualService** = Routing rules
- Where traffic goes (which service, which version)
- Routing by path, headers, weights
- Retry, timeout, fault injection

**DestinationRule** = Destination policies
- Define subsets (v1, v2, v3)
- Load balancing strategy
- Circuit breaker, connection pool

**Analogy:**
```
Gateway = Pintu masuk mall
VirtualService = Petunjuk arah ("Toko A lantai 2, 80% ke kasir lama, 20% ke kasir baru")
DestinationRule = Aturan toko ("Kasir lama = yang pakai seragam merah, max 10 antrian")
```

---

### Traffic Flow

**Internal (service-to-service):**
```
sleep pod → istio-proxy sidecar → mTLS → istio-proxy sidecar → httpbin pod
```

**External (via Gateway):**
```
Internet → Ingress Gateway Pod → Gateway Resource → VirtualService → DestinationRule → httpbin pod
```

---

### Key Benefits

1. **No code changes** - All features via configuration
2. **Consistent policies** - Same retry/timeout for all services
3. **Automatic security** - mTLS by default
4. **Observability** - Metrics & tracing out of the box
5. **Traffic control** - Canary, A/B testing, blue-green
6. **Resilience** - Retry, timeout, circuit breaker

---

## Next Steps

1. ~~Install Istio Ingress Gateway deployment~~ (optional, for external access)
2. ~~Test external access via Gateway~~
3. ✅ Access Kiali UI untuk visualisasi service mesh
4. ✅ Implement canary deployment (80/20 split)
5. ✅ Configure retry, timeout, circuit breaker
6. Test fault injection untuk chaos engineering
7. Monitor metrics di Kiali & Jaeger


## Test traffic canary
```bash
kubectl delete pod -n workload -l app=sleep && sleep 10 && SLEEP_POD=$(kubectl get pod -n workload -l app=sleep -o jsonpath='{.items[0].metadata.name}') && echo "Sending 100 requests..." && for i in {1..100}; do kubectl exec -n workload $SLEEP_POD -- curl -s http://httpbin:8000/get > /dev/null 2>&1; done && echo "Results:" && kubectl exec -n workload $SLEEP_POD -c istio-proxy -- curl -s localhost:15000/clusters | grep "httpbin-v.*rq_success"
```