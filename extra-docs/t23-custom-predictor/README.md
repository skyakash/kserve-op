# T23 — Custom multi-arch TinyLlama predictor

Reference build artifacts for the T23 (Design D) real-LLM test. Used to work around the upstream KServe v0.16 arm64 image-publishing gap (both `kserve/huggingfaceserver:latest` and `ghcr.io/llm-d/llm-d-dev:v0.2.2` publish `linux/amd64` only — neither pulls on Apple Silicon kind nodes).

Files:
- **`Dockerfile`** — minimal Python 3.11 base + CPU-only PyTorch + HuggingFace transformers + FastAPI + uvicorn. Multi-arch (`linux/amd64` + `linux/arm64`).
- **`app.py`** — FastAPI app exposing `/healthz`, `/v1/models`, and OpenAI-style `/v1/chat/completions`. Loads `TinyLlama/TinyLlama-1.1B-Chat-v1.0` from HuggingFace at container startup.

## Build + push

```bash
cd extra-docs/t23-custom-predictor

docker buildx create --name multi-arch-builder --use   # one-time setup

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag docker.io/<your-account>/tinyllama-predictor:v1 \
  --push \
  --provenance=false \
  --sbom=false \
  .
```

Build time: ~20–25 minutes on the first run (multi-arch + heavy torch/transformers stack). Resulting image is ~248 MB compressed; ~1 GB uncompressed.

## Deploy via `InferenceService` (Design D workload ns)

```bash
cat <<'EOF' | kubectl apply -n "${KSERVE_WORKLOAD_NS:-default}" -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: tinyllama
  annotations:
    serving.kserve.io/deploymentMode: "RawDeployment"
spec:
  predictor:
    containers:
      - name: kserve-container
        image: docker.io/<your-account>/tinyllama-predictor:v1
        ports: [ { containerPort: 8080, protocol: TCP } ]
        readinessProbe:
          httpGet: { path: /healthz, port: 8080 }
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 60
        resources:
          requests: { cpu: "1", memory: "3Gi" }
          limits:   { cpu: "2", memory: "5Gi" }
EOF

kubectl wait --for=condition=Ready isvc/tinyllama -n "${KSERVE_WORKLOAD_NS:-default}" --timeout=600s
```

## Inference

```bash
kubectl run --rm -i curl-test --image=curlimages/curl --restart=Never -- \
  curl -s -X POST -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What is 2+2? Reply briefly."}],"max_tokens":40,"temperature":0.0}' \
  http://tinyllama-predictor.${KSERVE_WORKLOAD_NS:-default}.svc.cluster.local/v1/chat/completions
```

Expected (verbatim from the T23 run on 2026-05-23):
```json
{"object":"chat.completion","model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0",
 "choices":[{"index":0,"message":{"role":"assistant","content":"2 + 2 = 4"},
             "finish_reason":"stop"}]}
```

## When to use this vs. upstream KServe runtimes

This custom image exists to bridge the arm64 gap **during local development on Apple Silicon**. For production deployments on amd64 hardware:
- **Prefer `kserve/huggingfaceserver`** (KServe's official multi-format HF runtime) once upstream publishes arm64 builds.
- **Prefer `LLMInferenceService` + `ghcr.io/llm-d/llm-d-dev`** for the full LLM-distributed-serving feature set (workload/router/scheduler/HTTPRoute) once upstream publishes arm64 builds.

For more context on why this artifact exists, see the T23 detail section in `../0.16-test-report.md`.
