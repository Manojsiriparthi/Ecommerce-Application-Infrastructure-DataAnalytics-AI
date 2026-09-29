# =============================================================================
# DB Setup — null_resource + local-exec
# =============================================================================
# WHAT:
#   After Aurora cluster + RDS Proxy are fully ready, this resource runs a
#   local-exec shell script that:
#     1. Connects kubectl to the EKS cluster
#     2. Launches a postgres:alpine pod INSIDE EKS (same VPC as Aurora)
#        to run CREATE DATABASE for each of the 5 service databases
#     3. Launches one pod per service to run `prisma db push`
#        (creates all tables — User, Product, CartItem, Order, OrderItem, Payment)
#     4. Runs a verify pod and prints a table report
#
# WHY local-exec + kubectl (not a data source or provider):
#   - Aurora is in a PRIVATE subnet. Terraform on your laptop cannot reach it.
#   - The EKS worker nodes are in the SAME VPC as Aurora — pods can reach it.
#   - local-exec runs on the machine running `terraform apply` (your laptop).
#     Your laptop uses `kubectl` which tunnels commands through the K8s API server,
#     and K8s schedules the pods on worker nodes that ARE in the VPC.
#   - This is the same pattern used in modules/compute/main.tf (post-deploy.sh).
#
# TRIGGERS:
#   Re-runs when:
#     - Aurora proxy endpoint changes (e.g. cluster replace)
#     - Master password changes
#     - You set force_db_setup = true in tfvars (breaks the trigger hash)
#
# SKIP CONDITIONS (handled inside the script, not here):
#   - ECR image doesn't exist yet → skips prisma push for that service
#   - SecretProviderClass not applied → skips prisma push (run 02-deploy-app.sh)
#   - EKS nodes not ready → aborts with a warning (re-run terraform apply)
# =============================================================================

locals {
  # Stable path to the script relative to this module's location.
  # Works whether called from environments/prod or environments/dev.
  db_setup_script = "${path.module}/scripts/create-databases.sh"

  # ECR registry URL — account_id.dkr.ecr.region.amazonaws.com
  ecr_registry = "${var.account_id}.dkr.ecr.${var.primary_region}.amazonaws.com"
}

resource "null_resource" "db_setup" {
  # ── WHEN TO RE-RUN ────────────────────────────────────────────────────────
  # Triggers are hashed — any change forces a re-run on next `terraform apply`.
  triggers = {
    # Re-run if the Aurora proxy endpoint changes (cluster was replaced)
    proxy_endpoint = aws_db_proxy.ecommerce.endpoint

    # Re-run if master password changes (new DATABASE_URLs in SSM)
    db_user = var.master_username

    # Manual re-run: set force_db_setup = "$(date)" in tfvars to force
    force = var.force_db_setup

    # Re-run if the script itself changes
    script_hash = filemd5("${path.module}/scripts/create-databases.sh")
  }

  # ── DEPENDS ON ────────────────────────────────────────────────────────────
  # Must wait for:
  #   - Aurora cluster + writer instance to be available
  #   - RDS Proxy to be fully configured (proxy → target group → cluster target)
  #   - SSM parameters (DATABASE_URLs) to be written
  #   - EKS cluster must exist (we check node readiness inside the script)
  depends_on = [
    aws_db_proxy_target.ecommerce,           # proxy is connected to Aurora
    aws_db_proxy_default_target_group.ecommerce,
    aws_ssm_parameter.db_url,               # DATABASE_URLs in SSM are ready
    aws_rds_cluster_instance.writer,         # writer instance is available
  ]

  # ── LOCAL-EXEC ────────────────────────────────────────────────────────────
  provisioner "local-exec" {
    # WHY env vars instead of positional args for the password:
    #   Terraform suppresses ALL output from local-exec when ANY sensitive value
    #   appears in the command string — even innocent log lines get hidden.
    #   Moving the password to `environment {}` keeps it out of the command string,
    #   so Terraform shows the script output normally while the password stays secret.
    command = <<-SHELL
      chmod +x "${local.db_setup_script}"
      bash "${local.db_setup_script}" \
        "${var.cluster_name}" \
        "${var.primary_region}" \
        "${aws_db_proxy.ecommerce.endpoint}" \
        "${var.master_username}" \
        "${local.ecr_registry}" \
        "${var.project_name}"
    SHELL

    # Password passed as env var — read inside the script as $TF_DB_PASS
    # This keeps the sensitive value out of the command string so Terraform
    # does NOT suppress script output.
    environment = {
      TF_DB_PASS = var.master_password
    }

    interpreter = ["bash", "-c"]
  }
}
