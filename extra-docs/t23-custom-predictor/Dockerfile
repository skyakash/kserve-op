# Multi-arch (linux/amd64 + linux/arm64) TinyLlama predictor for KServe Design D T23.
#
# Built locally to work around the upstream gap: KServe v0.16's
# kserve/huggingfaceserver:latest is published amd64-only, so on Apple Silicon
# (arm64) Docker Desktop's kind cluster it can't be pulled. This image is the
# minimum viable replacement: HF transformers + FastAPI + TinyLlama, served on
# port 8080 with an OpenAI-style /v1/chat/completions endpoint.
FROM python:3.11-slim

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TRANSFORMERS_NO_ADVISORY_WARNINGS=1 \
    HF_HUB_DISABLE_TELEMETRY=1

# Install Python deps first (separate layer for cache friendliness).
# torch is the heavy one (~700 MB amd64, ~400 MB arm64) — pinned to a stable
# CPU build via the index-url override so we don't pull CUDA wheels.
RUN pip install --upgrade pip && \
    pip install --extra-index-url https://download.pytorch.org/whl/cpu \
        "torch>=2.2,<2.5" \
        "transformers>=4.41,<4.50" \
        "fastapi>=0.111" \
        "uvicorn[standard]>=0.30" \
        "accelerate>=0.30" \
        "pydantic>=2.0"

WORKDIR /app
COPY app.py /app/app.py

EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
