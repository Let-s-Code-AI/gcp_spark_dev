variable "project_id" { type = string }
variable "region" { type = string }
variable "env" { type = string }
variable "name_suffix" { type = string }
variable "data_bucket" { type = string }
variable "dataproc_sa_email" { type = string }
variable "grafana_invokers" { type = list(string) }
