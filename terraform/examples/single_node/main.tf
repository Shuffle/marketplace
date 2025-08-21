module "shuffle" {
  source = "../.."

  project_id              = var.project_id
  goog_cm_deployment_name = "shuffle-single-node"
  region                  = "australia-southeast1"
  node_count              = 1
  machine_type            = "e2-standard-2"
  boot_disk_size          = 120
  boot_disk_type          = "pd-standard"
  enable_ssh              = true
}

variable "project_id" {
  description = "Google Cloud Project ID"
  type        = string
}

output "frontend_url" {
  value = module.shuffle.shuffle_frontend_url
}

