module "shuffle" {
  source = "../.."

  project_id              = var.project_id
  goog_cm_deployment_name = "shuffle-ha-cluster"
  region                  = "australia-southeast1"
  node_count              = 5 # All nodes are managers
  machine_type            = "e2-standard-4"
  boot_disk_size          = 200
  boot_disk_type          = "pd-ssd"
  enable_ssh              = true
  enable_cloud_monitoring = true
  enable_cloud_logging    = true
}

variable "project_id" {
  description = "Google Cloud Project ID"
  type        = string
}

output "frontend_url" {
  value = module.shuffle.shuffle_frontend_url
}


output "cluster_info" {
  value = {
    total_nodes   = module.shuffle.total_nodes
    manager_nodes = module.shuffle.manager_nodes
    nfs_server_ip = module.shuffle.nfs_server_ip
  }
}