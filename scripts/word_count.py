"""
Klasyczny Word Count — przykład joba PySpark na Dataproc.
Uruchomienie: gcloud dataproc jobs submit pyspark word_count.py \
                --cluster=<nazwa> --region=<region> \
                -- gs://<bucket>/input/ gs://<bucket>/output/

Job wysyła ślady i metryki przez OTLP do OpenTelemetry Collectora działającego
na węźle (http://localhost:4318). Bez bibliotek OpenTelemetry albo bez
collectora job działa normalnie, tylko bez telemetrii.
"""

import os
import sys
import time
from contextlib import contextmanager

from pyspark.sql import SparkSession

# Init action klastra instaluje biblioteki OpenTelemetry w osobnym katalogu,
# żeby nie podmieniać pakietów (np. protobuf) w środowisku conda Dataproc
OTEL_PYTHON_DIR = "/opt/otel-python"
if os.path.isdir(OTEL_PYTHON_DIR):
    sys.path.insert(0, OTEL_PYTHON_DIR)

try:
    from opentelemetry.exporter.otlp.proto.http.metric_exporter import (
        OTLPMetricExporter,
    )
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    OTEL_AVAILABLE = True
except ImportError:
    OTEL_AVAILABLE = False

SERVICE_NAME = "word_count"


class Telemetry:
    """Ślady i metryki joba; bez bibliotek OpenTelemetry wszystko jest no-op."""

    def __init__(self) -> None:
        self.enabled = OTEL_AVAILABLE
        if not self.enabled:
            print(
                "OpenTelemetry niedostępne — job działa bez telemetrii", file=sys.stderr
            )
            return

        # Eksportery domyślnie wysyłają na http://localhost:4318
        # (do zmiany przez OTEL_EXPORTER_OTLP_ENDPOINT)
        resource = Resource.create({"service.name": SERVICE_NAME})

        self._tracer_provider = TracerProvider(resource=resource)
        self._tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
        self._tracer = self._tracer_provider.get_tracer(SERVICE_NAME)

        self._meter_provider = MeterProvider(
            resource=resource,
            metric_readers=[PeriodicExportingMetricReader(OTLPMetricExporter())],
        )
        meter = self._meter_provider.get_meter(SERVICE_NAME)
        self._distinct_words = meter.create_gauge(
            "wordcount.distinct_words",
            unit="{word}",
            description="Liczba unikalnych słów w danych wejściowych",
        )
        self._duration = meter.create_histogram(
            "wordcount.duration",
            unit="s",
            description="Czas trwania joba",
        )

    @contextmanager
    def span(self, name: str, **attributes: str):
        if not self.enabled:
            yield
            return
        with self._tracer.start_as_current_span(name, attributes=attributes):
            yield

    def record(self, distinct_words: int, duration_s: float) -> None:
        if not self.enabled:
            return
        self._distinct_words.set(distinct_words)
        self._duration.record(duration_s)

    def shutdown(self) -> None:
        # Job jest krótki — bez tego dane nie zdążą wyjść przed końcem procesu
        if not self.enabled:
            return
        self._tracer_provider.shutdown()
        self._meter_provider.shutdown()


def main(input_path: str, output_path: str) -> None:
    telemetry = Telemetry()
    started = time.monotonic()

    spark = SparkSession.builder.appName("WordCount").getOrCreate()
    sc = spark.sparkContext

    try:
        with telemetry.span(
            "word_count", input_path=input_path, output_path=output_path
        ):
            lines = sc.textFile(input_path)
            counts = (
                lines.flatMap(lambda line: line.split())
                .map(lambda word: (word.lower(), 1))
                .reduceByKey(lambda a, b: a + b)
                .sortBy(lambda pair: pair[1], ascending=False)
            )
            counts.cache()

            # Transformacje Sparka są leniwe — pracę wykonują dopiero akcje,
            # więc to one dostają własne spany
            with telemetry.span("count_words"):
                distinct_words = counts.count()

            with telemetry.span("save_output"):
                counts.saveAsTextFile(output_path)

        telemetry.record(distinct_words, time.monotonic() - started)
    finally:
        spark.stop()
        telemetry.shutdown()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Użycie: word_count.py <input_path> <output_path>", file=sys.stderr)
        sys.exit(1)

    main(sys.argv[1], sys.argv[2])
