terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }
}

variable "project_id" {
  description = "The target GCP project ID"
  type        = string
  default     = "antigravity-demos-505721"
}

variable "region" {
  description = "The region for resources"
  type        = string
  default     = "us-central1"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ------------------------------------------------------------------------------
# VPC & Networking (Private by Default)
# ------------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "secure-architecture-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "web-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

# Private Services Access for Cloud SQL (Requirement 2)
resource "google_compute_global_address" "private_ip_address" {
  name          = "db-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

# ------------------------------------------------------------------------------
# Security Requirement 3: Customer Managed KMS Key for DB Encryption
# ------------------------------------------------------------------------------
resource "google_kms_key_ring" "db_keyring" {
  name     = "secure-db-keyring"
  location = var.region
}

resource "google_kms_crypto_key" "db_kms_key" {
  name            = "secure-db-key"
  key_ring        = google_kms_key_ring.db_keyring.id
  rotation_period = "2592000s" # 30 days
}

# Grant Cloud SQL Service Agent permissions to use the KMS key
resource "google_project_service_identity" "sql_sa" {
  provider = google-beta
  service  = "sqladmin.googleapis.com"
}

resource "google_kms_crypto_key_iam_binding" "crypto_key_binding" {
  crypto_key_id = google_kms_crypto_key.db_kms_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  members       = ["serviceAccount:${google_project_service_identity.sql_sa.email}"]
}

# ------------------------------------------------------------------------------
# Security Requirement 2: Private Database
# ------------------------------------------------------------------------------
resource "google_sql_database_instance" "database" {
  name             = "secure-app-db"
  database_version = "POSTGRES_15"
  region           = var.region

  # Requirement 3: Encrypted at rest
  encryption_key_name = google_kms_crypto_key.db_kms_key.id

  depends_on = [
    google_service_networking_connection.private_vpc_connection,
    google_kms_crypto_key_iam_binding.crypto_key_binding
  ]

  settings {
    tier = "db-f1-micro"
    ip_configuration {
      ipv4_enabled    = false # Inaccessible from the public internet
      private_network = google_compute_network.vpc.id
    }
  }
  
  deletion_protection = false # Set to true for production
}

# ------------------------------------------------------------------------------
# Web Servers (Cloud Run via Direct VPC Egress)
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "web_servers" {
  name     = "web-servers"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY" # Only accessible internally or via API GW

  template {
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello" # Placeholder web server image
      env {
        name  = "DB_HOST"
        value = google_sql_database_instance.database.private_ip_address
      }
    }
    
    # Securely route egress traffic into the VPC to reach the database
    vpc_access {
      network_interfaces {
        network    = google_compute_network.vpc.id
        subnetwork = google_compute_subnetwork.subnet.id
      }
    }
  }
}

# Service Account for API Gateway to invoke Web Servers
resource "google_service_account" "api_gw_sa" {
  account_id   = "api-gateway-sa"
  display_name = "API Gateway Service Account"
}

resource "google_cloud_run_service_iam_member" "api_gw_invoker" {
  location = google_cloud_run_v2_service.web_servers.location
  service  = google_cloud_run_v2_service.web_servers.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.api_gw_sa.email}"
}

# ------------------------------------------------------------------------------
# API Gateway
# ------------------------------------------------------------------------------
resource "google_api_gateway_api" "api" {
  provider = google-beta
  api_id   = "secure-client-api"
}

resource "google_api_gateway_api_config" "api_config" {
  provider      = google-beta
  api           = google_api_gateway_api.api.api_id
  api_config_id = "secure-api-config"

  openapi_documents {
    document {
      path = "openapi.yaml"
      contents = base64encode(<<-EOF
        swagger: "2.0"
        info:
          title: Secure API
          version: 1.0.0
        paths:
          /*:
            get:
              operationId: proxy
              x-google-backend:
                address: ${google_cloud_run_v2_service.web_servers.uri}
              responses:
                '200':
                  description: Success
      EOF
      )
    }
  }
  
  gateway_config {
    backend_config {
      google_service_account = google_service_account.api_gw_sa.email
    }
  }
}

resource "google_api_gateway_gateway" "api_gw" {
  provider   = google-beta
  gateway_id = "secure-gateway"
  api_config = google_api_gateway_api_config.api_config.id
  region     = var.region
}

# ------------------------------------------------------------------------------
# Security Requirement 1: Web Application Firewall (Cloud Armor) & Load Balancer
# ------------------------------------------------------------------------------
resource "google_compute_security_policy" "waf_policy" {
  name        = "api-gateway-waf"
  description = "WAF protecting the API Gateway"

  rule {
    action   = "allow"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow rule"
  }

  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        # Pre-configured WAF rule to block SQL injection
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
    description = "Block SQL Injection"
  }
}

# Serverless NEG to connect the Load Balancer to the API Gateway
resource "google_compute_region_network_endpoint_group" "api_gw_neg" {
  provider              = google-beta
  name                  = "api-gw-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  
  serverless_deployment {
    platform = "apigateway.googleapis.com"
    resource = google_api_gateway_gateway.api_gw.gateway_id
  }
}

resource "google_compute_backend_service" "backend" {
  name            = "api-gw-backend"
  protocol        = "HTTPS"
  security_policy = google_compute_security_policy.waf_policy.id

  backend {
    group = google_compute_region_network_endpoint_group.api_gw_neg.id
  }
}

resource "google_compute_url_map" "url_map" {
  name            = "api-url-map"
  default_service = google_compute_backend_service.backend.id
}

resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "api-http-proxy"
  url_map = google_compute_url_map.url_map.id
}

resource "google_compute_global_forwarding_rule" "forwarding_rule" {
  name       = "api-forwarding-rule"
  target     = google_compute_target_http_proxy.http_proxy.id
  port_range = "80"
}

output "load_balancer_ip" {
  description = "The public IP of the Load Balancer (WAF protected entry point)"
  value       = google_compute_global_forwarding_rule.forwarding_rule.ip_address
}
