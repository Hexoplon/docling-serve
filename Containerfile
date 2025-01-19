# Use a multi-stage build to reduce final image size
FROM python:3.11-slim-bookworm as builder

ENV \
  SSL_URL=${SSL_URL:-google.com} \
  PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
  SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

RUN openssl s_client -connect ${SSL_URL}:443 -showcerts </dev/null 2>/dev/null \
  | sed -e '/-----BEGIN/,/-----END/!d' \
  | tee "/usr/local/share/ca-certificates/ca.crt" >/dev/null \
  && update-ca-certificates

ARG CPU_ONLY=false
WORKDIR /docling-serve

# Combine apt commands and cleanup in single layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libgl1 \
        libglib2.0-0 \
        curl \
        wget \
        git \
        python3-setuptools \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Upgrade pip first, then install other packages
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir poetry setuptools && \
    poetry config virtualenvs.create false

# Set Poetry cache directory
ENV POETRY_CACHE_DIR=/tmp/poetry_cache

# Copy only dependency files first to leverage cache
COPY pyproject.toml poetry.lock README.md /docling-serve/

# Install dependencies with cache directory specified
RUN --mount=type=cache,target=$POETRY_CACHE_DIR if [ "$CPU_ONLY" = "true" ]; then \
    poetry install --no-root --with cpu --no-interaction --no-ansi --all-extras; \
    else \
    poetry install --no-root --no-interaction --no-ansi --all-extras; \
    fi

# Copy application code
COPY ./docling_serve /docling-serve/docling_serve

# Start new stage with clean image
FROM python:3.11-slim-bookworm

# Install required runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libgl1 \
        libglib2.0-0 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy CA certificates from builder
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Set SSL cert environment variables
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# Copy only necessary files from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /docling-serve /docling-serve

WORKDIR /docling-serve

# Set environment variables in final stage
ENV HF_HOME=/tmp/ \
    TORCH_HOME=/tmp/ \
    OMP_NUM_THREADS=4

# Download models in final stage
RUN python -c 'from docling.pipeline.standard_pdf_pipeline import StandardPdfPipeline; artifacts_path = StandardPdfPipeline.download_models_hf(force=True);'
ARG OCR_LANGUAGES="en,no"
RUN python -c "import easyocr; reader = easyocr.Reader('${OCR_LANGUAGES}'.split(','), gpu=True); print('EasyOCR models downloaded successfully')"

EXPOSE 5000

ENTRYPOINT ["python", "-m", "uvicorn", "--host", "0.0.0.0", "docling_serve.app:app", "--port", "5000"]
CMD ["--workers", "4"]
