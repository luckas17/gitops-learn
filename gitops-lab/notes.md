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

## Next Steps

1. Install Istio Ingress Gateway deployment
2. Test external access via Gateway
3. Access Kiali UI untuk visualisasi service mesh
4. Setup port-forward untuk akses Kiali:
   ```bash
   kubectl port-forward -n istio-system svc/kiali 20001:20001
   ```
5. Test traffic policies (retry, timeout, circuit breaker)
