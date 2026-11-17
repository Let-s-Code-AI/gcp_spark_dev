#!/usr/bin/env bash
# Pobiera z internetu paczkę OpenTelemetry Collector i wheels OpenTelemetry
# dla Pythona, po czym wgrywa je do GCS. Węzły Dataproc nie mają wyjścia do
# internetu, więc init action (install_otel.sh) instaluje wszystko z bucketu.
#
# Uruchamiany przez Terraform (terraform_data.otel_artifacts, local-exec),
# czyli na runnerze CI w jobie apply. Wymaga: curl, python3 z pip, gcloud.
#
# Zmienne środowiskowe:
#   DEST_URI                 np. gs://spark-data-dev-abc123/otel/artifacts/0.165.0-py1.45.2
#   OTELCOL_VERSION          wersja otelcol-contrib
#   OTELCOL_DEB_SHA256       oczekiwana suma SHA-256 paczki .deb
#   OTEL_PYTHON_VERSION      wersja opentelemetry-sdk / exportera OTLP
#   DATAPROC_PYTHON_VERSION  wersja Pythona na obrazie Dataproc (np. 3.11)

set -euo pipefail

: "${DEST_URI:?}" "${OTELCOL_VERSION:?}" "${OTELCOL_DEB_SHA256:?}"
: "${OTEL_PYTHON_VERSION:?}" "${DATAPROC_PYTHON_VERSION:?}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

DEB="${WORK_DIR}/otelcol-contrib.deb"
RELEASES="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download"

echo "==> Pobieranie otelcol-contrib ${OTELCOL_VERSION}"
curl -fsSL --retry 3 -o "${DEB}" \
  "${RELEASES}/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_amd64.deb"

if command -v sha256sum >/dev/null; then
  ACTUAL_SHA256="$(sha256sum "${DEB}" | cut -d' ' -f1)"
else
  ACTUAL_SHA256="$(shasum -a 256 "${DEB}" | cut -d' ' -f1)" # macOS
fi
if [[ "${ACTUAL_SHA256}" != "${OTELCOL_DEB_SHA256}" ]]; then
  echo "Błędna suma SHA-256 paczki .deb: ${ACTUAL_SHA256} (oczekiwano ${OTELCOL_DEB_SHA256})" >&2
  exit 1
fi

echo "==> Pobieranie wheels OpenTelemetry ${OTEL_PYTHON_VERSION} (Python ${DATAPROC_PYTHON_VERSION}, linux x86_64)"
cat >"${WORK_DIR}/requirements.txt" <<REQ
opentelemetry-sdk==${OTEL_PYTHON_VERSION}
opentelemetry-exporter-otlp-proto-http==${OTEL_PYTHON_VERSION}
REQ
python3 -m pip download --quiet \
  --dest "${WORK_DIR}/wheels" \
  --only-binary=:all: \
  --implementation cp \
  --python-version "${DATAPROC_PYTHON_VERSION}" \
  --platform manylinux2014_x86_64 \
  --platform manylinux_2_28_x86_64 \
  -r "${WORK_DIR}/requirements.txt"
cp "${WORK_DIR}/requirements.txt" "${WORK_DIR}/wheels/requirements.txt"

echo "==> Wgrywanie do ${DEST_URI}"
gcloud storage cp --quiet "${DEB}" "${DEST_URI}/otelcol-contrib.deb"
gcloud storage cp --quiet --recursive "${WORK_DIR}/wheels" "${DEST_URI}/"

echo "==> Gotowe"
