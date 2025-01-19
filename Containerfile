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
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install poetry and configure it to not create virtual environment
RUN pip install --no-cache-dir poetry && \
    poetry config virtualenvs.create false

# Copy only dependency files first to leverage cache
COPY pyproject.toml poetry.lock README.md /docling-serve/

# Install dependencies
RUN if [ "$CPU_ONLY" = "true" ]; then \
    poetry install --no-root --with cpu --no-interaction --no-ansi; \
    else \
    poetry install --no-root --no-interaction --no-ansi; \
    fi

# Set environment variables
ENV HF_HOME=/tmp/ \
    TORCH_HOME=/tmp/ \
    OMP_NUM_THREADS=4

# Download models
RUN poetry run python -c 'from docling.pipeline.standard_pdf_pipeline import StandardPdfPipeline; artifacts_path = StandardPdfPipeline.download_models_hf(force=True);'
RUN poetry run python -c 'import easyocr; reader = easyocr.Reader(["en", "no"], gpu=True); print("EasyOCR models downloaded successfully")'
RUN poetry run python -c 'import tesserocr; print("Tesseract models downloaded successfully")'
RUN poetry run python -c 'import rapidocr_onnxruntime; print("RapidOCR models downloaded successfully")'

# Copy application code
COPY ./docling_serve /docling-serve/docling_serve

# Start new stage with clean image
FROM python:3.11-slim-bookworm

# Copy CA certificates from builder
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Set SSL cert environment variables
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# Copy only necessary files from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
# Copy downloaded model files from builder
COPY --from=builder /tmp/.cache/huggingface /tmp/.cache/huggingface
COPY --from=builder /tmp/.cache/torch /tmp/.cache/torch
COPY --from=builder /tmp/.cache/easyocr /tmp/.cache/easyocr
COPY --from=builder /tmp/.cache/rapidocr /tmp/.cache/rapidocr

COPY --from=builder /docling-serve /docling-serve

WORKDIR /docling-serve

# Set environment variables in final stage
ENV HF_HOME=/tmp/ \
    TORCH_HOME=/tmp/ \
    OMP_NUM_THREADS=4

EXPOSE 5000

CMD ["python", "-m", "uvicorn", "--port", "5000", "--host", "0.0.0.0", "docling_serve.app:app"]
