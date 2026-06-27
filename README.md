# aws_ecs_iac_floci
Floci and Terraform based simple ECS-Fargate Setup with own VPC, ECR-Repository and a dummy FastAPI service. 

[Floci](https://floci.io) is a local emulator for AWS services, created as a drop-in replacement for LocalStack without auth tokens, without an account, and without restrictions. Unlike pure mocking tools, Floci uses real backends for many services (e.g., a real PostgreSQL/MySQL instance for RDS, real Redis for ElastiCache, real Docker containers for Lambda/ECS), allowing infrastructure code like Terraform to be tested realistically and at no cost before deploying it against real AWS.

## Prerequisites
- Flici
- Terraform
- Docker
- AWS CLI v2
- uv

## Setup Floci
Floci runs locally on port 4566 (`floci start` or Docker) including a Docker socket mount (required for ECS/Fargate tasks).

```docker
docker run -d --name floci \
    -p 4566:4566 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    floci/floci:latest
```

Export Env vars for Floci:
```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=test # can be any value
export AWS_SECRET_ACCESS_KEY=test # can be any value
```