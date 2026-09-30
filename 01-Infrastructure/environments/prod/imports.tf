# =============================================================================
# Terraform Import Blocks — INTENTIONALLY EMPTY
# =============================================================================
# Previously this file held commented-out import blocks used to adopt
# CloudWatch log groups that survive `terraform destroy` (AWS keeps them by
# design). That approach was fragile: the imports fail if the log groups DON'T
# exist, and must be toggled by hand depending on state — exactly the manual
# toil we want gone.
#
# REPLACED BY: 06-Scripts/00-pre-apply-cleanup.sh
#   Run that script before re-applying after a destroy. It DELETES the surviving
#   log groups (and other survivors) in both regions, so `terraform apply` then
#   CREATES them fresh with zero "already exists" errors and zero imports.
#
# Keep this file empty (no import blocks) so applies are deterministic.
# =============================================================================
