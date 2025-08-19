variable "project_id" {
  description = "The Google Cloud project ID"
  type        = string
}

variable "goog_cm_deployment_name" {
  description = "Deployment name from Google Cloud Marketplace"
  type        = string
}

variable "region" {
  description = "The Google Cloud region for deployment"
  type        = string
  default     = "australia-southeast1"
}

variable "zones" {
  description = "List of zones for instance deployment. If empty, will auto-select from region"
  type        = list(string)
  default     = []
}

variable "node_count" {
  description = "Total number of nodes in the Shuffle cluster (min 1, max 10)"
  type        = number
  default     = 1

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 10
    error_message = "Node count must be between 1 and 10"
  }
}

variable "machine_type" {
  description = "GCP machine type for Shuffle nodes"
  type        = string
  default     = "e2-standard-2"
}

variable "boot_disk_size" {
  description = "Boot disk size in GB"
  type        = number
  default     = 120

  validation {
    condition     = var.boot_disk_size >= 50 && var.boot_disk_size <= 1000
    error_message = "Boot disk size must be between 50 and 1000 GB"
  }
}

variable "boot_disk_type" {
  description = "Boot disk type"
  type        = string
  default     = "pd-standard"

  validation {
    condition     = contains(["pd-standard", "pd-ssd", "pd-balanced"], var.boot_disk_type)
    error_message = "Boot disk type must be pd-standard, pd-ssd, or pd-balanced"
  }
}

variable "source_image" {
  description = "Source image for VMs. If empty, uses Ubuntu 22.04 LTS"
  type        = string
  default     = ""
}

variable "subnet_cidr" {
  description = "CIDR range for the Shuffle subnet"
  type        = string
  default     = "10.224.0.0/16"
}

variable "external_access_cidrs" {
  description = "Comma-separated CIDR ranges allowed to access Shuffle UI"
  type        = string
  default     = "0.0.0.0/0"
}

# HTTPS is not exposed externally for security
# Access is only via port 3001

variable "enable_ssh" {
  description = "Enable SSH access to nodes"
  type        = bool
  default     = true
}

variable "ssh_source_ranges" {
  description = "Comma-separated CIDR ranges allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "environment" {
  description = "Environment label (dev, staging, production)"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be dev, staging, or production"
  }
}

variable "enable_cloud_logging" {
  description = "Enable Google Cloud Logging"
  type        = bool
  default     = true
}

variable "enable_cloud_monitoring" {
  description = "Enable Google Cloud Monitoring"
  type        = bool
  default     = true
}

variable "shuffle_admin_user" {
  description = "Admin username for Shuffle"
  type        = string
  default     = "admin@shuffle.local"
}

variable "shuffle_org_name" {
  description = "Organization name for Shuffle"
  type        = string
  default     = "Shuffle Organization"
}