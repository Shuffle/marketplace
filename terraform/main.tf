terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  deployment_name = var.goog_cm_deployment_name
  network_name    = "${local.deployment_name}-network"

  zones = length(var.zones) > 0 ? var.zones : data.google_compute_zones.available.names

  total_nodes   = var.node_count
  manager_nodes = min(var.node_count, 3)
  worker_nodes  = max(0, var.node_count - local.manager_nodes)

  opensearch_replicas       = min(local.total_nodes, 3)
  opensearch_index_replicas = local.opensearch_replicas - 1
  opensearch_initial_masters = join(",", [
    for i in range(1, local.opensearch_replicas + 1) : "shuffle-opensearch-${i}"
  ])
}

data "google_compute_zones" "available" {
  project = var.project_id
  region  = var.region
  status  = "UP"
}

resource "random_password" "admin_password" {
  length  = 16
  special = true
}

resource "google_compute_network" "shuffle_network" {
  name                    = local.network_name
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "shuffle_subnet" {
  name          = "${local.deployment_name}-subnet"
  network       = google_compute_network.shuffle_network.id
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  project       = var.project_id
}

resource "google_compute_firewall" "swarm_internal" {
  name    = "${local.deployment_name}-swarm-internal"
  network = google_compute_network.shuffle_network.name
  project = var.project_id

  # Docker Swarm cluster communication (internal only)
  allow {
    protocol = "tcp"
    ports    = ["2376", "2377", "7946"]
  }

  allow {
    protocol = "udp"
    ports    = ["7946", "4789"]
  }

  # NFS for shared storage (internal only)
  allow {
    protocol = "tcp"
    ports    = ["2049", "111", "51771"]
  }

  # Internal services (OpenSearch, Backend, Workers)
  allow {
    protocol = "tcp"
    ports    = ["9200", "9300", "5001", "5002", "33333", "33334", "33335", "33336"]
  }

  # Memcached
  allow {
    protocol = "tcp"
    ports    = ["11211"]
  }

  source_ranges = [var.subnet_cidr]
  target_tags   = ["${local.deployment_name}-node"]
}

resource "google_compute_firewall" "shuffle_external" {
  name    = "${local.deployment_name}-external"
  network = google_compute_network.shuffle_network.name
  project = var.project_id

  # ONLY expose port 3001 (Frontend HTTP) externally
  allow {
    protocol = "tcp"
    ports    = ["3001"]
  }

  allow {
    protocol = "udp"
    ports    = ["3001"]
  }

  source_ranges = split(",", var.external_access_cidrs)
  target_tags   = ["${local.deployment_name}-node"]
}

resource "google_compute_firewall" "ssh" {
  count   = var.enable_ssh ? 1 : 0
  name    = "${local.deployment_name}-ssh"
  network = google_compute_network.shuffle_network.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = split(",", var.ssh_source_ranges)
  target_tags   = ["${local.deployment_name}-node"]
}

resource "google_compute_instance" "swarm_manager" {
  count        = local.manager_nodes
  name         = "${local.deployment_name}-manager-${count.index + 1}"
  machine_type = var.machine_type
  zone         = local.zones[count.index % length(local.zones)]
  project      = var.project_id

  boot_disk {
    initialize_params {
      image = var.source_image != "" ? var.source_image : "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
      size  = var.boot_disk_size
      type  = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.shuffle_subnet.id

    access_config {
      network_tier = "PREMIUM"
    }
  }

  metadata = {
    enable-oslogin = "FALSE"

    node-role       = "manager"
    node-index      = count.index
    is-primary      = count.index == 0 ? "true" : "false"
    deployment-name = local.deployment_name
    total-nodes     = local.total_nodes
    manager-nodes   = local.manager_nodes
    worker-nodes    = local.worker_nodes

    nfs-master-ip   = count.index == 0 ? "self" : "PRIMARY_MANAGER_IP"
    primary-manager = count.index == 0 ? "self" : "PRIMARY_MANAGER_IP"

    opensearch-replicas        = local.opensearch_replicas
    opensearch-index-replicas  = local.opensearch_index_replicas
    opensearch-initial-masters = local.opensearch_initial_masters

    admin-password = random_password.admin_password.result

    startup-script = file("${path.module}/scripts/startup-simple.sh")
  }

  service_account {
    scopes = [
      "https://www.googleapis.com/auth/compute.readonly",
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write"
    ]
  }

  tags = ["${local.deployment_name}-node", "${local.deployment_name}-manager"]

  labels = {
    deployment  = local.deployment_name
    node-role   = "manager"
    environment = var.environment
  }

  depends_on = [
    google_compute_firewall.swarm_internal,
    google_compute_firewall.shuffle_external
  ]
}

resource "google_compute_instance" "swarm_worker" {
  count        = local.worker_nodes
  name         = "${local.deployment_name}-worker-${count.index + 1}"
  machine_type = var.machine_type
  zone         = local.zones[(count.index + local.manager_nodes) % length(local.zones)]
  project      = var.project_id

  boot_disk {
    initialize_params {
      image = var.source_image != "" ? var.source_image : "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
      size  = var.boot_disk_size
      type  = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.shuffle_subnet.id

    access_config {
      network_tier = "PREMIUM"
    }
  }

  metadata = {
    enable-oslogin = "FALSE"

    node-role       = "worker"
    node-index      = count.index + local.manager_nodes
    deployment-name = local.deployment_name
    total-nodes     = local.total_nodes

    nfs-master-ip   = "PRIMARY_MANAGER_IP"
    primary-manager = "PRIMARY_MANAGER_IP"

    opensearch-replicas        = local.opensearch_replicas
    opensearch-index-replicas  = local.opensearch_index_replicas
    opensearch-initial-masters = local.opensearch_initial_masters

    startup-script = file("${path.module}/scripts/startup-simple.sh")
  }

  service_account {
    scopes = [
      "https://www.googleapis.com/auth/compute.readonly",
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write"
    ]
  }

  tags = ["${local.deployment_name}-node", "${local.deployment_name}-worker"]

  labels = {
    deployment  = local.deployment_name
    node-role   = "worker"
    environment = var.environment
  }

  depends_on = [
    google_compute_instance.swarm_manager,
    google_compute_firewall.swarm_internal,
    google_compute_firewall.shuffle_external
  ]
}

resource "google_compute_instance_group" "managers" {
  count = local.manager_nodes > 0 ? 1 : 0

  name    = "${local.deployment_name}-managers"
  zone    = local.zones[0]
  project = var.project_id

  instances = [for instance in google_compute_instance.swarm_manager : instance.self_link]

  named_port {
    name = "http"
    port = 3001
  }

  named_port {
    name = "https"
    port = 3443
  }
}