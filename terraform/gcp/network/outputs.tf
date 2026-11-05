output "vpc_id" {
  description = "VPC self link"
  value       = google_compute_network.vpc.id
}

output "vpc_name" {
  description = "VPC name"
  value       = google_compute_network.vpc.name
}

output "public_subnet_self_link" {
  description = "Public subnet self link"
  value       = google_compute_subnetwork.public.self_link
}

output "private_subnet_self_link" {
  description = "Private subnet self link (attach app instances here)"
  value       = google_compute_subnetwork.private.self_link
}

output "proxy_subnet_self_link" {
  description = "Proxy-only subnet self link (REGIONAL_MANAGED_PROXY)"
  value       = google_compute_subnetwork.proxy.self_link
}

output "instance_group_self_link" {
  description = "Unmanaged instance group self link (LB backend)"
  value       = google_compute_instance_group.app.self_link
}

output "lb_ip_address" {
  description = "External HTTPS load balancer IP — point the cert domain's A record here"
  value       = google_compute_global_address.lb_ip.address
}

output "managed_cert_id" {
  description = "Google-managed SSL certificate id (12-hostname cert)"
  value       = google_compute_managed_ssl_certificate.cert_v2.id
}
