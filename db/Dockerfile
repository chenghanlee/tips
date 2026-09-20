FROM postgres:18.6-trixie@sha256:86c951e05bf56c93d95d397747fb8820ac76cc3bedb78f43abd83eedbe3666ae

ARG TARGETARCH
LABEL org.opencontainers.image.source="https://github.com/chenghanlee/tips"

RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) textsearch_sha=c2ce0585a7f09ec7fc441f1fba11888d6ad3ab51b1851d4f24a7457905d0519f ;; \
      arm64) textsearch_sha=f65bc4f46393ca66c78e4da71ae8c54d0aef9975eaf3d5b6836d0f4570c68c64 ;; \
      *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    test "$(dpkg --print-architecture)" = "$TARGETARCH"; \
    postgres_before="$(postgres --version)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip; \
    vector_version='0.8.6-1.pgdg13+1'; \
    if ! apt-cache show "postgresql-18-pgvector=$vector_version" >/dev/null 2>&1; then \
      echo 'deb [signed-by=/usr/local/share/keyrings/postgres.gpg.asc] https://apt-archive.postgresql.org/pub/repos/apt trixie-pgdg main' > /etc/apt/sources.list.d/pgvector-archive.list; \
      printf 'Package: postgresql-18-pgvector\nPin: origin apt-archive.postgresql.org\nPin-Priority: 500\n\nPackage: *\nPin: origin apt-archive.postgresql.org\nPin-Priority: -1\n' > /etc/apt/preferences.d/pgvector-archive; \
      apt-get update; \
    fi; \
    mkdir /tmp/extensions; \
    cd /tmp/extensions; \
    apt-get download "postgresql-18-pgvector=$vector_version"; \
    curl --fail --location --retry 3 --output textsearch.zip \
      "https://github.com/timescale/pg_textsearch/releases/download/v1.4.0/pg-textsearch-v1.4.0-pg18-${TARGETARCH}.zip"; \
    echo "$textsearch_sha  textsearch.zip" | sha256sum --check --strict; \
    unzip textsearch.zip; \
    sha256sum ./*.deb; \
    apt-get install -y --no-install-recommends ./postgresql-18-pgvector_*.deb; \
    dpkg -i "pg-textsearch-postgresql-18_1.4.0-1_${TARGETARCH}.deb"; \
    apt-get purge -y --auto-remove curl unzip; \
    test "$(postgres --version)" = "$postgres_before"; \
    dpkg-query -W postgresql-18 postgresql-18-pgvector pg-textsearch-postgresql-18; \
    rm -rf /tmp/extensions /var/lib/apt/lists/*

CMD ["postgres", "-c", "shared_preload_libraries=pg_textsearch"]
