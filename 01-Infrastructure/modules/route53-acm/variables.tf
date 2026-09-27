variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name (dev / prod)"
  type        = string
}

variable "domain_name" {
  description = <<-EOT
    Root domain name for this environment.
    Must be registered in Route53 Domains (or another registrar with NS pointed to Route53).
    Example: "ecommerce-pip.com"
    The module creates the hosted zone, issues an ACM cert, and adds A-records.
  EOT
  type        = string
}

variable "alb_dns_name" {
  description = <<-EOT
    DNS name of the external ALB created by the AWS Load Balancer Controller.
    Available only after kubectl apply of frontend/ingress.yaml.
    Leave empty ("") on first terraform apply — A-records will be skipped.
    Set on second apply (targeted) after the ALB is provisioned:
      terraform apply -target=module.route53_acm -var alb_dns_name=<ALB_DNS>
    The infra pipeline's post-apply stage retrieves this from:
      kubectl get ingress frontend-external-ingress -n ecommerce \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  EOT
  type        = string
  default     = ""
}

variable "alb_zone_id" {
  description = <<-EOT
    Hosted Zone ID of the external ALB (not the Route53 zone — the ALB's own zone ID).
    Required for Route53 alias records.
    ALBs in each region have a fixed zone ID:
      ap-south-1  = Z11127IXD6XFTK
      us-east-1   = Z35SXDOTRQ7X7K
      us-west-2   = Z1H1FL5HABSF5
      eu-west-1   = Z32O12XQLNTSW2
    Full list: https://docs.aws.amazon.com/general/latest/gr/elb.html
  EOT
  type        = string
  default     = ""
}
