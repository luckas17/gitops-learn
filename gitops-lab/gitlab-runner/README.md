# GitLab Runner - Lightweight Setup

GitLab Runner lightweight menggunakan Alpine Linux, optimized untuk K3d di Colima.

## Deploy

```bash
kubectl apply -f application.yaml
```

## Lightweight Features

- **Image**: Alpine 3.19 (~5MB vs Ubuntu ~80MB)
- **Helper**: gitlab-runner-helper:alpine-latest
- **Resources**: 50m CPU / 64Mi RAM (request), 200m CPU / 256Mi RAM (limit)
- **Privileged**: false (lebih aman)
- **Executor**: Kubernetes (job jalan sebagai pod)

## Verify

```bash
# Check status
kubectl get pods -n gitlab-runner
kubectl logs -n gitlab-runner -l app=gitlab-runner -f

# Verify di GitLab
# Settings > CI/CD > Runners (harus muncul online)
```

## Example .gitlab-ci.yml

```yaml
test:
  image: alpine:3.19
  tags:
    - k3d
  script:
    - echo "Running on lightweight K3d runner"
    - apk add --no-cache curl
    - curl -I https://gitlab.com
```

## Notes

- Kalau butuh Docker builds, ganti `privileged: true` dan pakai image `docker:24-alpine`
- Resource bisa di-adjust sesuai kebutuhan
- Runner auto-register dan sync via ArgoCD
