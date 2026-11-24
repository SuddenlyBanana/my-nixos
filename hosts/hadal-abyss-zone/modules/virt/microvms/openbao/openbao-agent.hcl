vault {
  address         = "https://[::1]:8202"
  ca_cert         = "/run/credentials/openbao-agent-openbao-tls.service/ca.crt"
  tls_server_name = "openbao.infra.windows.moe"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/run/credentials/openbao-agent-openbao-tls.service/role-id"
      secret_id_file_path                 = "/run/credentials/openbao-agent-openbao-tls.service/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template_config {
  exit_on_retry_failure = false
}

template {
  source               = "@TEMPLATE_SOURCE@"
  destination          = "/var/lib/openbao/tls-staging/bundle.pem"
  perms                = "0600"
  backup               = false
  error_on_missing_key = true
}
