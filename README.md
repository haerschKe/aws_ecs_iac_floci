# aws_ecs_iac_floci
Floci and Terraform based simple ECS-Fargate Setup with own VPC, ECR-Repository and a dummy FastAPI service. 

[Floci](https://floci.io) is a local emulator for AWS services, created as a drop-in replacement for LocalStack without auth tokens, without an account, and without restrictions. Unlike pure mocking tools, Floci uses real backends for many services (e.g., a real PostgreSQL/MySQL instance for RDS, real Redis for ElastiCache, real Docker containers for Lambda/ECS), allowing infrastructure code like Terraform to be tested realistically and at no cost before deploying it against real AWS.

## Prerequisites
- Floci
- Terraform
- Docker
- AWS CLI v2
- uv

## Local development without Docker

```bash
cd app
uv sync
uv run uvicorn main:app --reload --port 8000
```

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

> Note: Floci also has a UI Dashboard which needs to be started separately

## Create the infrastructure

**Customization**: All relevant settings live in `variables.tf`:
- `desired_count` – number of Fargate tasks (default: 2)
- `task_cpu` / `task_memory` – task size
- `container_port` – port of the FastAPI service
- `public_subnet_cidrs` / `availability_zones` – network layout

### 1. Create the ECR repository first
So the image can be built and pushed before the full infrastructure deployment, we first create just the ECR repository, in a targeted way:

```bash
cd iac
terraform init
terraform apply -target=aws_ecr_repository.app
```

Note down the repo URL:

```bash
REPO_URL=$(terraform output -raw ecr_repository_url)
echo $REPO_URL

# OR
terraform output -raw ecr_repository_url
```

### 2. Build and push the Docker image
Before the first build, a `uv.lock` file must be generated once:
```bash
cd ../app
uv lock
```

Floci runs a real OCI registry for ECR, so a normal `docker push` works:

```bash
REPO_URL=$(cd ../iac && terraform output -raw ecr_repository_url)

# Log in against the local ECR registry
aws ecr get-login-password --endpoint-url $AWS_ENDPOINT_URL \
  | docker login --username AWS --password-stdin "${REPO_URL%%/*}"

docker build -t fastapi-dummy:latest .
docker tag fastapi-dummy:latest "${REPO_URL}:latest"
docker push "${REPO_URL}:latest"
```

### 3. Create the remaining (complete) infrastructure
```bash
cd terraform
terraform init
terraform apply
```

This creates: a VPC with 2 public subnets (2 AZs), an Internet
Gateway, an ECR repository, IAM roles, an ECS cluster, a task
definition (with the placeholder image tag `latest`), and the ECS
service with 2 Fargate tasks.

> Note: If the ECR Repository is not created before `tf apply`, the ECS service already tries to start
> tasks – this will fail as long as no image exists in the ECR repo
> yet. This is harmless; just push the Image afterwards and redeploy the
> service to pick up the new task definition with the now available image.
> ```bash
> aws ecs update-service \
>  --cluster $(terraform output -raw ecs_cluster_name) \
>  --service $(terraform output -raw ecs_service_name) \
>  --force-new-deployment \
>  --endpoint-url $AWS_ENDPOINT_URL
>```

## Check tasks and reachable addresses
```bash
CLUSTER=$(terraform output -raw ecs_cluster_name)
SERVICE=$(terraform output -raw ecs_service_name)

# List running tasks
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE \
  --endpoint-url $AWS_ENDPOINT_URL --query 'taskArns[0]' --output text)

# Inspect status and attachments
aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN \
  --endpoint-url $AWS_ENDPOINT_URL
```

> **Known limitation:** Floci often does not fully populate the
> `attachments` array for `awsvpc`-mode tasks with complete ENI
> details (`networkInterfaceId`, `privateIPv4Address`, etc.), so
> `tasks[0].attachments[0].details` can return `null` even when the
> task is running. In addition, Floci does not publish a host port for
> the container in `awsvpc` mode (unlike `bridge` mode with an
> explicit `hostPort`) - in real AWS semantics there isn't one either
> in `awsvpc` mode, since the task gets its own ENI directly. This is
> a gap in Floci's ECS emulation, not a bug in this setup.

## Call the service
**Workaround:** Since Floci runs ECS tasks as real Docker containers,
we test via a temporary sidecar container **on the same Docker
network** as the task. This works reliably on Linux *and* on Docker
Desktop (macOS/Windows) - a direct `curl` from the host to the
container IP, by contrast, often fails on Docker Desktop due to the
network isolation of the Docker VM, since without host-port publishing
there is no route from the host to the internal container IP.

```bash
CONTAINER_ID=$(docker ps --filter "name=fastapi" --format "{{.ID}}" | head -1)
echo "Container_ID: $CONTAINER_ID"

# Determine the container's Docker network
NETWORK=$(docker inspect "$CONTAINER_ID" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
echo "Network: $NETWORK"

# IP address of the container on this network
TARGET_IP=$(docker inspect "$CONTAINER_ID" --format "{{(index .NetworkSettings.Networks \"$NETWORK\").IPAddress}}")
echo "Container IP: $TARGET_IP"

# Test via a sidecar on the same network
docker run --rm --network "$NETWORK" curlimages/curl -s "http://$TARGET_IP:8000/"
docker run --rm --network "$NETWORK" curlimages/curl -s "http://$TARGET_IP:8000/health"
```

Output:
```bash
# for /
{"message":"Hello from FastAPI running on Floci ECS Fargate!","hostname":"30c44473d847"}

# for /health
{"status":"ok"}
```

## 5. Clean up

```bash
terraform destroy
```



## Known limitations with Floci

- In `awsvpc` network mode, Floci does not publish a host port for the
  task containers (see step 4) - access only works via the
  container's Docker network, not via an address directly reachable
  from the host. As a result, `assign_public_ip = true` has no
  practical effect in the local emulation.
- **Docker Desktop (macOS/Windows):** A direct `curl` from the host to
  the internal container IP generally does not work due to the
  network isolation of the Docker VM. On native Linux Docker this may
  work depending on the setup, but the sidecar-container workaround
  from step 4 is the more reliable, host-OS-independent method.
- ENI attachment details (`attachments[].details` in `describe-tasks`)
  are not fully populated for `awsvpc`-mode tasks – see the workaround
  in step 4.
- An Application Load Balancer was deliberately omitted here (see the
  architecture decision); if needed, `aws_lb`, `aws_lb_target_group`,
  and `aws_lb_listener` can be added and the service wired up via a
  `load_balancer { }` block in `aws_ecs_service`.