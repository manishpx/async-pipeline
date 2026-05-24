resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "main" {
  identifier              = "${local.name}-pg"
  engine                  = "postgres"
  engine_version          = "16"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 50
  max_allocated_storage   = 200
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.pipeline.arn
  db_name                 = var.db_name
  username                = var.db_username
  password                = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  multi_az                = true
  backup_retention_period = 1
  skip_final_snapshot     = true # flip for prod
  deletion_protection     = false # flip for prod
  publicly_accessible     = false
  performance_insights_enabled = true
}