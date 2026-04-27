output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${var.TargetRegion} update-kubeconfig --name ${local.ClusterBaseName}"
}

# Grafana (monitoring 네임스페이스) — kubeconfig 반영 후 사용
output "grafana_port_forward" {
  description = "터미널에서 실행 후 유지 → 브라우저로 Grafana 접속"
  value       = "kubectl port-forward -n monitoring svc/grafana 3000:80"
}

output "grafana_url" {
  description = "포트 포워드 후 브라우저 주소 (로그인 사용자: admin)"
  value       = "http://localhost:3000"
}

output "grafana_admin_password_command" {
  description = "PowerShell에서 Grafana admin 비밀번호 출력 (Secret: grafana)"
  value       = <<-EOT
    kubectl get secret -n monitoring grafana -o jsonpath="{.data.admin-password}" | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }
  EOT
}
