output "deployment_name" {
  description = "Name of the deployment"
  value       = local.deployment_name
}

output "shuffle_frontend_url" {
  description = "URL to access Shuffle Frontend"
  value       = "http://${google_compute_instance.swarm_manager[0].network_interface[0].access_config[0].nat_ip}:3001"
}

# HTTPS port 3443 is not exposed externally for security
# Internal access only via Docker Swarm overlay network

output "opensearch_internal_url" {
  description = "Internal URL to access OpenSearch (not exposed externally)"
  value       = "http://${google_compute_instance.swarm_manager[0].network_interface[0].network_ip}:9200"
}

output "admin_password" {
  description = "Admin password for Shuffle (auto-generated)"
  value       = random_password.admin_password.result
  sensitive   = true
}


output "manager_instances" {
  description = "List of manager instance details"
  value = [for instance in google_compute_instance.swarm_manager : {
    name        = instance.name
    internal_ip = instance.network_interface[0].network_ip
    external_ip = instance.network_interface[0].access_config[0].nat_ip
    zone        = instance.zone
  }]
}

output "worker_instances" {
  description = "List of worker instance details"
  value = [for instance in google_compute_instance.swarm_worker : {
    name        = instance.name
    internal_ip = instance.network_interface[0].network_ip
    external_ip = instance.network_interface[0].access_config[0].nat_ip
    zone        = instance.zone
  }]
}

output "total_nodes" {
  description = "Total number of nodes in the cluster"
  value       = local.total_nodes
}

output "manager_nodes" {
  description = "Number of manager nodes"
  value       = local.manager_nodes
}

output "worker_nodes" {
  description = "Number of worker nodes"
  value       = local.worker_nodes
}

output "network_name" {
  description = "Name of the VPC network"
  value       = google_compute_network.shuffle_network.name
}

output "subnet_name" {
  description = "Name of the subnet"
  value       = google_compute_subnetwork.shuffle_subnet.name
}

output "nfs_server_ip" {
  description = "IP address of the NFS server (primary manager)"
  value       = google_compute_instance.swarm_manager[0].network_interface[0].network_ip
}

output "swarm_join_command_manager" {
  description = "Command to join swarm as manager (retrieve from primary manager)"
  value       = "SSH to primary manager and run: docker swarm join-token manager"
}

output "swarm_join_command_worker" {
  description = "Command to join swarm as worker (retrieve from primary manager)"
  value       = "SSH to primary manager and run: docker swarm join-token worker"
}

output "post_deployment_instructions" {
  description = "Instructions after deployment"
  value       = <<-EOT
    =================================================================
    Shuffle Deployment Complete!
    =================================================================
    
    Access URLs:
    - Frontend (External): http://${google_compute_instance.swarm_manager[0].network_interface[0].access_config[0].nat_ip}:3001
    - OpenSearch (Internal): http://${google_compute_instance.swarm_manager[0].network_interface[0].network_ip}:9200
    
    Note: Only port 3001 is exposed externally for security.
    All other services are accessible only within the VPC.
     
    Cluster Information:
    - Total Nodes: ${local.total_nodes}
    - Manager Nodes: ${local.manager_nodes}
    - Worker Nodes: ${local.worker_nodes}
    
    Management:
    - SSH to primary manager: gcloud compute ssh ${google_compute_instance.swarm_manager[0].name} --zone=${google_compute_instance.swarm_manager[0].zone}
    - View stack: docker stack services shuffle
    - View logs: docker service logs shuffle_<service-name>
    
    =================================================================
  EOT
}