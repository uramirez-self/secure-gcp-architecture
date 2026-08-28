# Secure GCP Architecture

This repository contains the Terraform configuration to deploy a secure, multi-tier web application architecture on Google Cloud Platform (GCP). The architecture adheres strictly to enterprise cloud security baselines, ensuring defense-in-depth from the edge to the database layer.

## Architecture Overview

The deployed infrastructure maps to a traditional web architecture (Users -> API Gateway -> Load Balancer -> Web Servers -> Database) using cloud-native GCP services:

- **Edge Security & Routing:** Global External Application Load Balancer with Google Cloud Armor (WAF).
- **API Management:** Google Cloud API Gateway.
- **Compute (Web Servers):** Google Cloud Run (Serverless) integrated with Direct VPC Egress.
- **Database:** Google Cloud SQL (PostgreSQL) deployed privately.
- **Encryption:** Cloud Key Management Service (KMS) for Customer-Managed Encryption Keys (CMEK).

## Security Controls Implemented

As a Lead Cloud Security Engineer, the following mandatory security controls have been baked into this IaC:

1. **Web Application Firewall (WAF):** Google Cloud Armor is deployed in front of the API Gateway via the Load Balancer. It includes a default deny posture for specific threats (e.g., pre-configured rules to block SQL Injection).
2. **Private Database Subnet:** The Cloud SQL instance is deployed with private IP only (`ipv4_enabled = false`). It does not have a public IP address and cannot be reached from the public internet. Access is strictly routed internally via Private Services Access and Direct VPC Egress from the Cloud Run instances.
3. **Encryption at Rest (CMEK):** The database storage is encrypted at rest using a Customer-Managed Encryption Key (CMEK) provisioned in Google Cloud KMS, adhering to strict data sovereignty and encryption compliance requirements.
4. **Least Privilege IAM:** Dedicated Service Accounts are used (e.g., API Gateway has a specific service account granted only the `roles/run.invoker` role to invoke the Cloud Run web servers).

## Prerequisites

- Terraform ~> 5.0 installed locally.
- Google Cloud CLI (`gcloud`) authenticated to your GCP environment.
- Sufficient IAM permissions in the target GCP Project to create VPCs, KMS Keys, IAM Bindings, Cloud Run services, API Gateways, and Cloud SQL instances.

## Deployment Instructions

1. **Clone the repository:**
   ```bash
   git clone https://github.com/uramirez-self/secure-gcp-architecture.git
   cd secure-gcp-architecture
   ```

2. **Configure Variables:**
   Update the `project_id` and `region` variables in `main.tf` if necessary, or pass them via a `.tfvars` file or command-line arguments. Default project is set to `antigravity-demos-505721`.

3. **Initialize Terraform:**
   ```bash
   terraform init
   ```

4. **Review the Execution Plan:**
   ```bash
   terraform plan
   ```

5. **Apply the Configuration:**
   ```bash
   terraform apply
   ```
   *Type `yes` when prompted to confirm the deployment.*

## Cleanup

To avoid incurring ongoing charges for these resources, destroy the infrastructure when you are finished:

```bash
terraform destroy
```

## Security Note

This repository contains infrastructure configurations. Do not commit sensitive data, secrets, or actual database passwords to this repository. Use a secure secrets manager (like Google Secret Manager) to inject sensitive runtime values.
