terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

locals {
  # Przypięte wersje — podbicie wersji = zmiana tutaj (i sumy SHA-256 paczki .deb)
  otelcol_version         = "0.165.0"
  otelcol_deb_sha256      = "dafb5174344dd15f339fd8208783b17122fb4cd37fa7e5461fb09d99df212b4b"
  otel_python_version     = "1.45.2"
  dataproc_python_version = "3.11" # Python na obrazie Dataproc 2.2
  grafana_image           = "docker.io/grafana/grafana:12.4.15"

  # Paczka .deb i wheels leżą w buckecie data, bo staging kasuje obiekty po 7 dniach
  otel_prefix        = "otel"
  otel_artifacts_uri = "gs://${var.data_bucket}/${local.otel_prefix}/artifacts/${local.otelcol_version}-py${local.otel_python_version}"

  grafana_files_dir = "${path.module}/files/grafana"
  grafana_files     = fileset(local.grafana_files_dir, "**")
}

# ─── OpenTelemetry Collector na węzłach Dataproc ─────────────────────────────

# Init action uruchamiany na każdym węźle przy tworzeniu klastra
resource "google_storage_bucket_object" "otel_init_action" {
  name    = "${local.otel_prefix}/install_otel.sh"
  bucket  = var.data_bucket
  content = file("${path.module}/files/otel/install_otel.sh")
}

resource "google_storage_bucket_object" "otel_collector_config" {
  name    = "${local.otel_prefix}/collector-config.yaml"
  bucket  = var.data_bucket
  content = file("${path.module}/files/otel/collector-config.yaml")
}

# Węzły nie mają wyjścia do internetu — binarkę collectora i wheels pobiera
# maszyna wykonująca apply (runner CI) i wgrywa do GCS.
resource "terraform_data" "otel_artifacts" {
  triggers_replace = {
    dest_uri    = local.otel_artifacts_uri
    deb_sha256  = local.otelcol_deb_sha256
    python      = local.dataproc_python_version
    script_hash = filesha256("${path.module}/files/otel/upload_artifacts.sh")
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/files/otel/upload_artifacts.sh"

    environment = {
      DEST_URI                = local.otel_artifacts_uri
      OTELCOL_VERSION         = local.otelcol_version
      OTELCOL_DEB_SHA256      = local.otelcol_deb_sha256
      OTEL_PYTHON_VERSION     = local.otel_python_version
      DATAPROC_PYTHON_VERSION = local.dataproc_python_version
    }
  }
}

# Uprawnienia SA Dataproc do wysyłania telemetrii
resource "google_project_iam_member" "dataproc_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${var.dataproc_sa_email}"
}

resource "google_project_iam_member" "dataproc_trace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${var.dataproc_sa_email}"
}

# ─── Grafana na Cloud Run ────────────────────────────────────────────────────
# Żyje poza klastrem, bo klaster kasuje się sam po idle_delete_ttl.

resource "google_service_account" "grafana" {
  account_id   = "grafana-${var.env}"
  display_name = "Grafana (${var.env})"
  project      = var.project_id
}

# Odczyt metryk (Cloud Monitoring + Managed Service for Prometheus)
resource "google_project_iam_member" "grafana_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.grafana.email}"
}

# Provisioning Grafany (datasource + dashboardy) montowany jako wolumen GCS.
# Dysk Cloud Run jest ulotny, więc dashboardy żyją w repo, nie w Grafanie.
resource "google_storage_bucket" "grafana_provisioning" {
  name          = "grafana-provisioning-${var.env}-${var.name_suffix}"
  project       = var.project_id
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true
}

resource "google_storage_bucket_object" "grafana_provisioning" {
  for_each = local.grafana_files

  name    = each.value
  bucket  = google_storage_bucket.grafana_provisioning.name
  content = replace(file("${local.grafana_files_dir}/${each.value}"), "__PROJECT_ID__", var.project_id)
}

resource "google_storage_bucket_iam_member" "grafana_provisioning_viewer" {
  bucket = google_storage_bucket.grafana_provisioning.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.grafana.email}"
}

resource "google_cloud_run_v2_service" "grafana" {
  name     = "grafana-${var.env}"
  project  = var.project_id
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account       = google_service_account.grafana.email
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2" # wymagane przez wolumen GCS

    scaling {
      min_instance_count = 0 # skalowanie do zera — płacisz tylko za użycie
      max_instance_count = 1 # stan Grafany jest lokalny, więc jedna instancja
    }

    containers {
      image = local.grafana_image

      ports {
        container_port = 3000
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      # Dostęp chroni IAM Cloud Run (roles/run.invoker), więc Grafana
      # wpuszcza bez własnego logowania. Editor pozwala używać Explore.
      env {
        name  = "GF_AUTH_ANONYMOUS_ENABLED"
        value = "true"
      }
      env {
        name  = "GF_AUTH_ANONYMOUS_ORG_ROLE"
        value = "Editor"
      }
      env {
        name  = "GF_AUTH_DISABLE_LOGIN_FORM"
        value = "true"
      }
      env {
        name  = "GF_AUTH_BASIC_ENABLED"
        value = "false"
      }
      env {
        name  = "GF_ANALYTICS_REPORTING_ENABLED"
        value = "false"
      }
      env {
        name  = "GF_ANALYTICS_CHECK_FOR_UPDATES"
        value = "false"
      }
      env {
        name  = "GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH"
        value = "/etc/grafana/provisioning/dashboards/json/spark-cluster.json"
      }
      # Zmiana plików provisioningu wymusza nową rewizję (Grafana czyta
      # datasource tylko przy starcie)
      env {
        name = "PROVISIONING_HASH"
        value = sha1(join(",", [
          for f in sort(tolist(local.grafana_files)) :
          google_storage_bucket_object.grafana_provisioning[f].md5hash
        ]))
      }

      volume_mounts {
        name       = "provisioning"
        mount_path = "/etc/grafana/provisioning"
      }
    }

    volumes {
      name = "provisioning"
      gcs {
        bucket    = google_storage_bucket.grafana_provisioning.name
        read_only = true
      }
    }
  }

  depends_on = [
    google_storage_bucket_iam_member.grafana_provisioning_viewer,
    google_project_iam_member.grafana_monitoring_viewer,
  ]
}

# Kto (poza Owner/Editor projektu) może otworzyć Grafanę
resource "google_cloud_run_v2_service_iam_member" "grafana_invoker" {
  for_each = toset(var.grafana_invokers)

  project  = var.project_id
  location = google_cloud_run_v2_service.grafana.location
  name     = google_cloud_run_v2_service.grafana.name
  role     = "roles/run.invoker"
  member   = each.value
}
