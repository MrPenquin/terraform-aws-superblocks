locals {
  node_heap = var.container_memory * 0.75
}

#################################################################
# Secrets Manager
#################################################################
resource "null_resource" "agent_key_sha" {
  count = var.superblocks_agent_key_from == null ? 1 : 0

  triggers = {
    agent_key = nonsensitive(sha512(var.superblocks_agent_key))
  }
}

resource "aws_secretsmanager_secret" "agent_key" {
  count = var.superblocks_agent_key_from == null ? 1 : 0

  name = "superblocks/agent/key"
}

resource "aws_secretsmanager_secret_version" "agent_key" {
  count = var.superblocks_agent_key_from == null ? 1 : 0

  secret_id                = aws_secretsmanager_secret.agent_key[0].id
  secret_string_wo         = var.superblocks_agent_key
  secret_string_wo_version = 1

  lifecycle {
    replace_triggered_by = [null_resource.agent_key_sha]
  }
}

resource "aws_iam_policy" "agent_key_policy" {
  count = var.superblocks_agent_key_from == null ? 1 : 0

  name        = "superblocks-agent-secrets-access"
  description = "Allow access to Superblocks agent secret"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue",
        ]
        Effect   = "Allow"
        Resource = aws_secretsmanager_secret.agent_key[0].arn
      }
    ]
  })
}

#################################################################
# VPC
#################################################################
module "vpc" {
  count  = var.create_vpc ? 1 : 0
  source = "./modules/vpc"
  name   = "${var.name_prefix}-vpc"
}

#################################################################
# Load Balancer
#################################################################
module "lb" {
  count  = var.create_lb ? 1 : 0
  source = "./modules/load-balancer"

  name_prefix        = var.name_prefix
  internal           = var.lb_internal
  vpc_id             = local.vpc_id
  subnet_ids         = local.lb_subnet_ids
  security_group_ids = var.lb_security_group_ids
  certificate_arn    = local.certificate_arn
  ssl_enable         = local.lb_ssl
  zone_name          = var.domain
  record_name        = var.subdomain
  create_dns         = var.create_dns
  dns_ttl            = var.dns_ttl
  depends_on         = [module.vpc]

  create_sg                   = var.create_lb_sg
  sg_ingress_with_cidr_blocks = var.lb_sg_ingress_with_cidr_blocks
  sg_egress_with_cidr_blocks  = var.lb_sg_egress_with_cidr_blocks

  private_zone = var.private_zone
}

#################################################################
# Certificate
#################################################################
module "certs" {
  count  = var.create_certs ? 1 : 0
  source = "./modules/certs"

  zone_name    = var.domain
  record_name  = var.subdomain
  private_zone = var.private_zone
  vpc_id       = var.private_zone ? local.vpc_id : null
}

#################################################################
# ECS
#################################################################
module "ecs" {
  source = "./modules/ecs"

  name_prefix            = var.name_prefix
  region                 = local.region
  subnet_ids             = local.ecs_subnet_ids
  security_group_ids     = var.ecs_security_group_ids
  target_group_http_arns = local.lb_target_group_http_arns
  target_group_grpc_arns = local.lb_target_group_grpc_arns

  task_role_arn                             = var.superblocks_agent_role_arn
  additional_ecs_execution_task_policy_arns = var.superblocks_agent_key_from == null ? concat(var.additional_ecs_execution_task_policy_arns, [aws_iam_policy.agent_key_policy[0].arn]) : var.additional_ecs_execution_task_policy_arns

  container_port_http               = local.superblocks_http_port
  container_port_grpc               = local.superblocks_grpc_port
  container_image                   = var.superblocks_agent_image
  repository_credentials_secret_arn = var.superblocks_repository_credentials_secret_arn
  # SUPERBLOCKS_AGENT_ENVIRONMENT is being passed for backwards compatibility with older versions of the agent
  container_environment = concat(
    [
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_LOG_LEVEL", "value" : "${var.superblocks_log_level}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_HTTP_PORT", "value" : "${local.superblocks_http_port}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_GRPC_PORT", "value" : "${local.superblocks_grpc_port}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_GRPC_MSG_RES_MAX", "value" : "${var.superblocks_grpc_msg_res_max}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_GRPC_MSG_REQ_MAX", "value" : "${var.superblocks_grpc_msg_req_max}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_SUPERBLOCKS_URL", "value" : "${var.superblocks_server_url}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_SUPERBLOCKS_TIMEOUT", "value" : "${var.superblocks_timeout}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_OTEL_COLLECTOR_HTTP_URL", "value" : "https://traces.intake.superblocks.com:443/v1/traces" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_EMITTER_REMOTE_INTAKE", "value" : "https://logs.intake.superblocks.com" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_INTAKE_METADATA_URL", "value" : "https://metadata.intake.superblocks.com" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_FILE_SERVER_URL", "value" : "http://127.0.0.1:${local.superblocks_http_port}/v2/files" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_AGENT_HOST_URL", "value" : "${local.agent_host_url}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_AGENT_ENVIRONMENT", "value" : "${var.superblocks_agent_environment}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_AGENT_TAGS", "value" : "${local.superblocks_agent_tags}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_DATA_DOMAIN", "value" : "${var.superblocks_agent_data_domain}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_HANDLE_CORS", "value" : "${var.superblocks_agent_handle_cors}" },
      { "name" : "SUPERBLOCKS_ORCHESTRATOR_QUOTAS_DEFAULT_API_TIMEOUT", "value" : "${var.superblocks_agent_quotas_default_api_timeout}" }
    ],
    var.superblocks_agent_environment_variables
  )
  container_secrets = var.superblocks_agent_key_from == null ? [
    { "name" : "SUPERBLOCKS_AGENT_KEY", "valueFrom" : "${aws_secretsmanager_secret.agent_key[0].arn}" },
    { "name" : "SUPERBLOCKS_ORCHESTRATOR_SUPERBLOCKS_KEY", "valueFrom" : "${aws_secretsmanager_secret.agent_key[0].arn}" },
    ] : [
    { "name" : "SUPERBLOCKS_AGENT_KEY", "valueFrom" : "${var.superblocks_agent_key_from}" },
    { "name" : "SUPERBLOCKS_ORCHESTRATOR_SUPERBLOCKS_KEY", "valueFrom" : "${var.superblocks_agent_key_from}" },
  ]

  container_cpu          = var.container_cpu
  container_memory       = var.container_memory
  container_min_capacity = var.container_min_capacity
  container_max_capacity = var.container_max_capacity

  create_sg                  = var.create_ecs_sg
  load_balancer_sg_ids       = concat(var.create_lb_sg && var.create_lb ? [module.lb[0].lb_security_group_id] : [], var.allowed_load_balancer_sg_ids)
  sg_egress_with_cidr_blocks = var.ecs_sg_egress_with_cidr_blocks
  vpc_id                     = local.vpc_id

  container_scale_up_when_cpu_pct_above = var.autoscaling_cpu_threshold_pct

  depends_on = [module.lb]
}
