vault {
  address         = "https://[@OPENBAO_ADDRESS@]:8200"
  ca_cert         = "/etc/openbao-ca/ca.crt"
  tls_server_name = "openbao.home.arpa"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/var/lib/postgresql/approle/postgresql-tls/role-id"
      secret_id_file_path                 = "/var/lib/postgresql/approle/postgresql-tls/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template_config {
  exit_on_retry_failure = false
}

template {
  source               = "@TEMPLATE_SOURCE@"
  destination          = "/var/lib/postgresql/tls-staging/bundle.pem"
  perms                = "0600"
  backup               = false
  error_on_missing_key = true
}
