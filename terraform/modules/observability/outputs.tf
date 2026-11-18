output "otel_init_action_uri" {
  value = "gs://${var.data_bucket}/${google_storage_bucket_object.otel_init_action.name}"
}

# Metadane węzłów, z których init action bierze lokalizację artefaktów
output "otel_node_metadata" {
  value = {
    "otel-artifacts-uri" = local.otel_artifacts_uri
    "otel-config-uri"    = "gs://${var.data_bucket}/${google_storage_bucket_object.otel_collector_config.name}"
  }

  # klaster może powstać dopiero, gdy artefakty są już w GCS
  depends_on = [terraform_data.otel_artifacts]
}

output "grafana_service_name" {
  value = google_cloud_run_v2_service.grafana.name
}

output "grafana_url" {
  value = google_cloud_run_v2_service.grafana.uri
}
