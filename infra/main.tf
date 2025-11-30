terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  backend "gcs" {
    bucket = "aare-ai-terraform-state"
    prefix = "terraform/state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-west1"
}

variable "environment" {
  description = "Environment name (prod, staging, dev)"
  type        = string
  default     = "prod"
}

# Enable required APIs
resource "google_project_service" "cloudfunctions" {
  service            = "cloudfunctions.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudbuild" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# Storage bucket for ontologies
resource "google_storage_bucket" "ontologies" {
  name          = "aare-ai-ontologies-${var.environment}"
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }
}

# Storage bucket for function source code
resource "google_storage_bucket" "function_source" {
  name          = "aare-ai-function-source-${var.environment}"
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true
}

# Archive the function source code
data "archive_file" "function_source" {
  type        = "zip"
  output_path = "${path.module}/function-source.zip"
  source_dir  = "${path.module}/.."
  excludes    = ["infra", ".git", ".github", "__pycache__", "*.pyc", ".venv", "venv"]
}

# Upload function source to GCS
resource "google_storage_bucket_object" "function_source" {
  name   = "function-source-${data.archive_file.function_source.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.function_source.output_path
}

# Service account for the function
resource "google_service_account" "function_sa" {
  account_id   = "aare-ai-function-${var.environment}"
  display_name = "aare.ai Cloud Function Service Account"
}

# Grant storage access to the function
resource "google_storage_bucket_iam_member" "function_storage_access" {
  bucket = google_storage_bucket.ontologies.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

# Cloud Function (2nd gen)
resource "google_cloudfunctions2_function" "verify" {
  name     = "aare-ai-verify-${var.environment}"
  location = var.region

  depends_on = [
    google_project_service.cloudfunctions,
    google_project_service.cloudbuild,
    google_project_service.run,
    google_project_service.artifactregistry,
  ]

  build_config {
    runtime     = "python311"
    entry_point = "verify"

    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.function_source.name
      }
    }
  }

  service_config {
    max_instance_count    = 100
    min_instance_count    = 0
    available_memory      = "2Gi"
    timeout_seconds       = 30
    service_account_email = google_service_account.function_sa.email

    environment_variables = {
      ONTOLOGY_BUCKET = google_storage_bucket.ontologies.name
      ENVIRONMENT     = var.environment
    }
  }
}

# Allow unauthenticated invocations (for public API)
# Remove this if you want to require authentication
resource "google_cloud_run_service_iam_member" "invoker" {
  location = google_cloudfunctions2_function.verify.location
  service  = google_cloudfunctions2_function.verify.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Outputs
output "function_url" {
  description = "The URL of the deployed function"
  value       = google_cloudfunctions2_function.verify.service_config[0].uri
}

output "ontology_bucket" {
  description = "The GCS bucket for ontologies"
  value       = google_storage_bucket.ontologies.name
}

output "verify_endpoint" {
  description = "The full verify endpoint URL"
  value       = "${google_cloudfunctions2_function.verify.service_config[0].uri}"
}
