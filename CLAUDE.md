# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Projekt szkoleniowy DevOps: mini klaster Apache Spark (GCP Dataproc) w `europe-central2`, zarządzany Terraformem. Komentarze, opisy zmiennych i dokumentacja są po polsku — trzymaj się tego.

## Polecenia

W repo nie ma testów. Jedyną bramką jakości jest lint, ten sam co w jobie `lint` w CI (`.github/workflows/terraform.yml`):

```bash
# Terraform
terraform fmt -check -recursive terraform/     # bez -check, żeby naprawić
cd terraform && tflint --init && tflint --recursive --format=compact
checkov -d terraform --framework terraform     # w CI soft_fail — tylko raport

# Python (konfiguracja w ruff.toml, target py39 = Python na Dataproc 2.1)
ruff check scripts/                            # --fix, żeby naprawić
ruff format --check scripts/
```

Terraform lokalnie (wymaga `gcloud auth application-default login` i istniejącego bucketu na state):

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # uzupełnij project_id
terraform init -backend-config="bucket=<BUCKET_NA_STATE>"   # CI dodaje też prefix=terraform/state
terraform validate
terraform plan
```

Uruchomienie joba na działającym klastrze:

```bash
./scripts/submit_job.sh <PROJECT_ID> europe-central2 spark-training-cluster "$(terraform -chdir=terraform output -raw data_bucket)"
```

Zmiany w infrastrukturze i w state idą wyłącznie przez GitHub Actions (workflow `terraform.yml`). Lokalnie wolno tylko czytać: `init`, `validate`, `plan`, `show`, `output`, `state list/show`. Polecenia modyfikujące (`apply`, `destroy`, `import`, `refresh`, `taint`/`untaint`, `state mv/rm/push`, `force-unlock`, `workspace new/delete`, `init -migrate-state`) są zablokowane dla Claude w `.claude/settings.json` (`permissions.deny`) — nie obchodź tej blokady. To samo dotyczy modyfikujących poleceń `gcloud` (create/delete/update/submit/IAM itd.), `gsutil` (cp/mv/rm/rsync, ustawienia bucketów) oraz `scripts/submit_job.sh`; `gcloud`/`gsutil` tylko do odczytu (`list`, `describe`, `ls`, `cat`).

## Architektura

Root module `terraform/main.tf` włącza wymagane API GCP i spina cztery moduły:

- `modules/network` — VPC, subnet `10.10.0.0/24` (z `private_ip_google_access`), firewall: SSH tylko z zakresu IAP oraz ruch wewnętrzny.
- `modules/storage` — buckety staging i data **oraz service account Dataproc z jego rolami IAM** (SA nie jest w module dataproc).
- `modules/observability` — OpenTelemetry Collector na węzłach (init action + konfiguracja w buckecie data), role SA Dataproc do wysyłki telemetrii (`monitoring.metricWriter`, `cloudtrace.agent`) oraz Grafana na Cloud Run z własnym SA i bucketem `grafana-provisioning-*`. Pliki nie-Terraformowe leżą w `files/`.
- `modules/dataproc` — klaster; dostaje `subnet_self_link` z network, `staging_bucket` i `service_account` ze storage oraz `init_action_uri` i `node_metadata` z observability.

Powiązania między modułami, których nie widać w jednym pliku:

- Tag sieciowy `dataproc-node` jest ustawiany na węzłach w `modules/dataproc` i używany jako `target_tags` w regułach firewall w `modules/network`. Zmiana w jednym miejscu wymaga zmiany w drugim.
- CIDR subnetu `10.10.0.0/24` jest wpisany na sztywno dwukrotnie w `modules/network/main.tf` (subnet i `source_ranges` reguły internal).
- Węzły nie mają publicznych IP (`internal_ip_only = true`) — dostęp do GCS działa dzięki Private Google Access, a SSH / Spark UI tylko przez tunel IAP (`terraform output spark_ui_port_forward`).
- Nazwy bucketów to `spark-{staging,data}-<env>-<6 znaków md5(project_id-env)>`. Nie składaj ich ręcznie — bierz z outputów `staging_bucket` / `data_bucket`.
- Węzły nie mają wyjścia do internetu, więc paczkę collectora i wheels OpenTelemetry pobiera `terraform_data.otel_artifacts` (`local-exec`, skrypt `upload_artifacts.sh`) na maszynie wykonującej apply i wgrywa do bucketu data — stąd `setup-gcloud` w jobie `apply`. Artefakty nie mogą leżeć w buckecie staging (kasuje obiekty po 7 dniach).
- Zmiana `initialization_action` lub metadanych węzłów wymusza odtworzenie klastra. Zmiana samej treści `collector-config.yaml` nie — trafia na węzły przy następnym utworzeniu klastra.
- Init action instaluje biblioteki OpenTelemetry w `/opt/otel-python` (nie w conda), a `scripts/word_count.py` dodaje ten katalog do `sys.path`. Ścieżka jest wpisana w obu plikach.
- Dashboard Grafany (`files/grafana/dashboards/json/*.json`) wymaga `git add -f` (`.gitignore` ignoruje `*.json`).
- Zmienna `zone` służy wyłącznie do zbudowania outputu `spark_ui_port_forward`; klaster jej nie dostaje.
- Backend `gcs` jest celowo pusty — bucket (i prefix) przychodzą przez `-backend-config`.

Nowa zmienna konfigurowalna przechodzi przez: `terraform/variables.tf` → przekazanie w `terraform/main.tf` → `modules/<x>/variables.tf` (+ `terraform.tfvars.example` i tabela w README). tflint wymusza m.in. `terraform_unused_declarations` i `required_version`/`required_providers` w każdym module.

### Pipeline CI (`.github/workflows/terraform.yml`)

`lint` → `plan` → `apply` → `spark-job`. Workflow uruchamia się wyłącznie ręcznie (`workflow_dispatch`) — nie reaguje na push ani PR. Sam dispatch robi tylko lint i plan; `apply` i `spark-job` ruszają tylko na `main` z zaznaczonym inputem (`run_apply`, `run_spark_job` — niezależne, domyślnie wyłączone), a `apply` wymaga ręcznego zatwierdzenia w environment `production`. Apply wykonuje zapisany artefakt `tfplan` z joba plan — bez `terraform refresh` przed nim, bo refresh zapisuje nową wersję state i unieważnia zapisany plan („Saved plan is stale”). Job `spark-job` odczytuje `data_bucket` i `cluster_name` z `terraform output` i wywołuje `scripts/submit_job.sh`. Uwierzytelnianie do GCP przez Workload Identity Federation (sekrety `WIF_PROVIDER`, `WIF_SERVICE_ACCOUNT`, `TF_STATE_BUCKET`, `GCP_PROJECT_ID`).
### Wykrywanie driftu (`.github/workflows/drift.yml`)

Codziennie (cron) i na żądanie (`workflow_dispatch`) robi `terraform plan -refresh-only -lock=false` i utrzymuje jedno issue z etykietą `drift`: tworzy je, aktualizuje i zamyka, gdy drift zniknie. Niczego nie naprawia i nie zapisuje state. Drift na `google_dataproc_cluster` jest pomijany (filtr `jq` w ostatnim kroku), bo klaster kasuje się sam po `idle_delete_ttl`.

## Znane niespójności

- README podaje `idle_delete_ttl = 3600s`; w kodzie (`modules/dataproc/main.tf`) jest `7200s`.
- `.gitignore` ignoruje `*.md` i `*.json`. README jest śledzony mimo tego; nowe pliki Markdown/JSON (w tym ten plik i `.claude/settings.json`) wymagają `git add -f`. Pliki `prezentacja*.md` wymienione w README istnieją tylko lokalnie u autora.

## Commits

This repo uses [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Every commit message follows this format:

```
<type>(<optional scope>): <short description>

<optional body — what and why>

<optional footer, e.g. BREAKING CHANGE: ...>
```

Allowed types:

- `feat` — new functionality
- `fix` — bug fix
- `docs` — documentation only (e.g. README)
- `refactor` — code change with no behavior change
- `style` — formatting, linter fixes (ruff)
- `test` — tests
- `ci` — GitHub Actions and pipelines
- `build` — dependencies, build tooling
- `chore` — other housekeeping
- `perf` — performance improvement
- `revert` — reverting a commit

Rules:

- Write commit messages in English.
- Description in the imperative mood, lowercase, no trailing period, up to about 72 characters.
- Scope is optional and names the area of the repo, e.g. `terraform`, `scripts`, `ci`.
- Breaking change: `!` after the type/scope (`feat(terraform)!: ...`) or a `BREAKING CHANGE: ...` footer.
- One commit = one logical change; do not mix types in a single commit.

Examples:

```
fix: add terraform refresh before apply to prevent stale plan errors
feat(scripts): add spark job submission script
ci: run ruff check on pull requests
style: apply ruff fixes
docs: update README with setup steps
```

Pull request titles use the same format.

The format is enforced by the `commit-msg` hook in `.githooks/`. Enable it once per clone with `git config core.hooksPath .githooks`. Do not bypass it with `--no-verify`.
