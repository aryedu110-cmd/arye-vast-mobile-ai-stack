FROM ubuntu:24.04

ARG CLOUDFLARED_VERSION=2026.8.2
ARG CLOUDFLARED_SHA256=fcfb02b575a52ca1af2e3267af4e1517bcdeb30ac48c834c69abaed3c0576ad2
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    ARYE_STATE_DIR=/workspace/arye-production/state \
    ARYE_HEALTH_PORT=8787 \
    LTX_ROOT=/workspace/arye-production/repos/LTX-2 \
    MODEL_ROOT=/workspace/arye-production/models/ltx-2.5 \
    OPENMONTAGE_ROOT=/workspace/arye-production/repos/OpenMontage \
    PROJECT_ROOT=/workspace/projects/why-math-matters \
    HF_HOME=/workspace/arye-production/hf-cache

RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
      build-essential ca-certificates curl ffmpeg git git-lfs jq make nodejs npm rsync unzip \
      libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
      python3 python3-dev python3-pip python3-venv \
    && curl --fail --location --silent --show-error \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64" \
      -o /usr/local/bin/cloudflared \
    && printf '%s  %s\n' "$CLOUDFLARED_SHA256" /usr/local/bin/cloudflared | sha256sum --check --status \
    && chmod 0755 /usr/local/bin/cloudflared \
    && python3 -m pip install --no-cache-dir --break-system-packages \
      'uv==0.8.14' 'huggingface_hub==0.34.4' \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh health_server.py bootstrap_ltx.sh gpu_acceptance_gates.sh install_openmontage.sh install_musetalk.sh install_chatterbox.sh install_optional_components.sh run_ltx_clip.sh verify_ready_state.sh self_stop.sh arm_watchdog.sh balance_watchdog.py qc_video.py queue_worker.py review_queue_job.py runtime_preflight.py /opt/arye-production/
RUN chmod 0755 /opt/arye-production/*.sh \
    && python3 -m py_compile /opt/arye-production/balance_watchdog.py /opt/arye-production/health_server.py /opt/arye-production/qc_video.py /opt/arye-production/queue_worker.py /opt/arye-production/review_queue_job.py /opt/arye-production/runtime_preflight.py

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:8787/healthz >/dev/null || exit 1

ENTRYPOINT ["/opt/arye-production/entrypoint.sh"]
