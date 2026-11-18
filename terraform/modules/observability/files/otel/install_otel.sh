#!/usr/bin/env bash
# Init action Dataproc: instaluje OpenTelemetry Collector (systemd) oraz
# biblioteki OpenTelemetry dla Pythona na każdym węźle klastra.
#
# Węzły nie mają dostępu do internetu, więc wszystko pochodzi z GCS
# (Private Google Access). Artefakty wgrywa tam upload_artifacts.sh.
#
# Monitoring nie może blokować klastra: każdy błąd kończy skrypt kodem 0
# i zostawia ostrzeżenie w logu init action (bucket staging,
# google-cloud-dataproc-metainfo/<cluster-uuid>/<node>/dataproc-initialization-script-0_output).

set -euo pipefail
trap 'echo "[otel] OSTRZEŻENIE: instalacja przerwana (linia ${LINENO}) — węzeł działa bez telemetrii"; exit 0' ERR

readonly METADATA=/usr/share/google/get_metadata_value
readonly PYTHON_BIN=/opt/conda/default/bin/python
readonly OTEL_PYTHON_DIR=/opt/otel-python

ARTIFACTS_URI="$("${METADATA}" attributes/otel-artifacts-uri)"
CONFIG_URI="$("${METADATA}" attributes/otel-config-uri)"
CLUSTER_NAME="$("${METADATA}" attributes/dataproc-cluster-name)"
WORK_DIR="$(mktemp -d)"

echo "[otel] Pobieranie artefaktów z ${ARTIFACTS_URI}"
gsutil -q cp "${ARTIFACTS_URI}/otelcol-contrib.deb" "${WORK_DIR}/otelcol-contrib.deb"
gsutil -q -m cp -r "${ARTIFACTS_URI}/wheels" "${WORK_DIR}/"
gsutil -q cp "${CONFIG_URI}" "${WORK_DIR}/config.yaml"

echo "[otel] Instalacja collectora"
dpkg -i "${WORK_DIR}/otelcol-contrib.deb"
install -m 0644 "${WORK_DIR}/config.yaml" /etc/otelcol-contrib/config.yaml

# Nazwa klastra dla ${env:DATAPROC_CLUSTER_NAME} w konfiguracji collectora
mkdir -p /etc/systemd/system/otelcol-contrib.service.d
cat >/etc/systemd/system/otelcol-contrib.service.d/dataproc.conf <<UNIT
[Service]
Environment=DATAPROC_CLUSTER_NAME=${CLUSTER_NAME}
UNIT

systemctl daemon-reload
systemctl enable otelcol-contrib
systemctl restart otelcol-contrib

# Osobny katalog zamiast środowiska conda: instalacja nie podmienia pakietów
# (np. protobuf), z których korzysta reszta klastra. Job dodaje go do sys.path.
echo "[otel] Instalacja bibliotek OpenTelemetry dla Pythona w ${OTEL_PYTHON_DIR}"
"${PYTHON_BIN}" -m pip install --quiet --no-index \
  --target "${OTEL_PYTHON_DIR}" \
  --find-links "${WORK_DIR}/wheels" \
  -r "${WORK_DIR}/wheels/requirements.txt"

rm -rf "${WORK_DIR}"
echo "[otel] Gotowe"
