FROM ubuntu:24.04

ARG CLOUDFLARED_VERSION=2026.8.2
ARG CLOUDFLARED_SHA256=fcfb02b575a52ca1af2e3267af4e1517bcdeb30ac48c834c69abaed3c0576ad2
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends ca-certificates curl python3 \
    && curl --fail --location --silent --show-error \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64" \
      -o /usr/local/bin/cloudflared \
    && printf '%s  %s\n' "$CLOUDFLARED_SHA256" /usr/local/bin/cloudflared | sha256sum --check --status \
    && chmod 0755 /usr/local/bin/cloudflared \
    && rm -rf /var/lib/apt/lists/*

COPY health_server.py /opt/arye-mobile-health/health_server.py
COPY entrypoint.sh /usr/local/bin/arye-mobile-health
RUN chmod 0755 /usr/local/bin/arye-mobile-health \
    && python3 -m py_compile /opt/arye-mobile-health/health_server.py

ENTRYPOINT ["/usr/local/bin/arye-mobile-health"]
