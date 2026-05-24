resource "aws_cloudwatch_log_group" "pipeline" {
  name              = "/ecs/${local.name}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.pipeline.arn
}

resource "aws_ecs_cluster" "main" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

locals {
  task_defs = {
    scrub  = { cpu = "1024", memory = "2048" } # Adjust CPU and memory as needed (e.g. 512/1024 for smaller tasks)
    enrich = { cpu = "1024", memory = "2048" } # Enrich might need more resources if it does heavy processing or API calls
    load   = { cpu = "1024", memory = "2048" } # Load might also need more resources if it handles DB connections and writes
  }
}

resource "aws_ecs_task_definition" "stage" {
  for_each                 = local.task_defs
  family                   = "${local.name}-${each.key}"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.task_exec.arn
  task_role_arn            = aws_iam_role.stage[each.key].arn

  container_definitions = jsonencode([{
    name      = each.key
    image     = "${var.ecr_repo_url}/${each.key}:${var.image_tag}"
    essential = true
    environment = [
      { name = "STAGE",            value = each.key },
      { name = "PROCESSED_BUCKET", value = aws_s3_bucket.processed.bucket },
      { name = "UPLOADS_BUCKET",   value = aws_s3_bucket.uploads.bucket },
      { name = "JOBS_TABLE",       value = aws_dynamodb_table.jobs.name },
      { name = "AWS_REGION",       value = var.region }
    ]
    secrets = each.key == "enrich" ? [
      { name = "ENRICH_API_KEY", valueFrom = "${aws_secretsmanager_secret.enrich_api.arn}:api_key::" }
    ] : each.key == "load" ? [
      { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db.arn}:password::" }
    ] : []
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.pipeline.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = each.key
      }
    }
  }])
}