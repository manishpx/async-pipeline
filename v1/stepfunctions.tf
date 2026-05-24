resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${local.name}"
  retention_in_days = 30
}

locals {
  network_config = {
    AwsvpcConfiguration = {
      Subnets        = aws_subnet.private[*].id
      SecurityGroups = [aws_security_group.tasks.id]
      AssignPublicIp = "DISABLED"
    }
  }

  run_stage = { for k, _ in local.task_defs : k => {
    Type     = "Task"
    Resource = "arn:aws:states:::ecs:runTask.sync"
    Parameters = {
      LaunchType           = "FARGATE"
      Cluster              = aws_ecs_cluster.main.arn
      TaskDefinition       = aws_ecs_task_definition.stage[k].arn
      NetworkConfiguration = local.network_config
      Overrides = {
        ContainerOverrides = [{
          Name = k
          Environment = [
            { "Name" = "JOB_ID",    "Value.$" = "$.jobId" },
            { "Name" = "INPUT_KEY", "Value.$" = "$.inputKey" }
          ]
        }]
      }
    }
  } }
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = local.name
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD"

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  definition = jsonencode({
    Comment = "CSV scrub -> enrich -> load"
    StartAt = "PrepareInput"
    States = {
      PrepareInput = {
        Type = "Pass"
        Parameters = {
          "jobId.$"    = "$.detail.object.key"
          "inputKey.$" = "$.detail.object.key"
        }
        Next = "RecordJob"
      }

      RecordJob = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:putItem"
        Parameters = {
          TableName = aws_dynamodb_table.jobs.name
          Item = {
            jobId     = { "S.$" = "$.jobId" }
            status    = { "S"   = "RUNNING" }
            stage     = { "S"   = "scrub" }
            startedAt = { "S.$" = "$$.State.EnteredTime" }
          }
        }
        ResultPath = null
        Next       = "Scrub"
      }

      Scrub = merge(local.run_stage["scrub"], {
        ResultPath = null
        Retry = [{
          ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 30, MaxAttempts = 2, BackoffRate = 2.0
        }]
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "MarkFailed", ResultPath = "$.error" }]
        Next  = "Enrich"
      })

      Enrich = merge(local.run_stage["enrich"], {
        ResultPath = null
        Retry = [{
          ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 60, MaxAttempts = 3, BackoffRate = 2.0
        }]
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "MarkFailed", ResultPath = "$.error" }]
        Next  = "Load"
      })

      Load = merge(local.run_stage["load"], {
        ResultPath = null
        Retry = [{
          ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 30, MaxAttempts = 2, BackoffRate = 2.0
        }]
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "MarkFailed", ResultPath = "$.error" }]
        Next  = "MarkSucceeded"
      })

      MarkSucceeded = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = aws_dynamodb_table.jobs.name
          Key       = { jobId = { "S.$" = "$.jobId" } }
          UpdateExpression          = "SET #s = :s, finishedAt = :t"
          ExpressionAttributeNames  = { "#s" = "status" }
          ExpressionAttributeValues = {
            ":s" = { "S"   = "SUCCEEDED" }
            ":t" = { "S.$" = "$$.State.EnteredTime" }
          }
        }
        ResultPath = null
        Next       = "NotifyUser"
      }

      NotifyUser = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.user_notify.arn
          Subject     = "CSV job complete"
          "Message.$" = "States.Format('Job {} finished successfully', $.jobId)"
        }
        End = true
      }

      MarkFailed = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = aws_dynamodb_table.jobs.name
          Key       = { jobId = { "S.$" = "$.jobId" } }
          UpdateExpression          = "SET #s = :s, errorInfo = :e"
          ExpressionAttributeNames  = { "#s" = "status" }
          ExpressionAttributeValues = {
            ":s" = { "S"   = "FAILED" }
            ":e" = { "S.$" = "States.JsonToString($.error)" }
          }
        }
        ResultPath = null
        Next       = "AlertOps"
      }

      AlertOps = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.ops_alerts.arn
          Subject     = "CSV pipeline FAILED"
          "Message.$" = "States.Format('Job {} failed: {}', $.jobId, States.JsonToString($.error))"
        }
        End = true
      }
    }
  })
}