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
cd iac
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

## Overview
This is the most simple setup for local testing but not suitable for a production setup (see [Production Setup](#production-setup)).

```bash
┌────────────────────────────────────────────-─┐
│  VPC (10.0.0.0/16)                           │
│  ┌──────────────┐      ┌──────────────┐      │
│  │ Public Subnet│      │ Public Subnet│      │
│  │   AZ-a       │      │   AZ-b       │      │
│  │              │      │              │      │
│  │  ECS Fargate │      │  ECS Fargate │      │
│  │  Task(s)     │      │  Task(s)     │      │
│  └──────────────┘      └──────────────┘      │
│         │                     │              │
│  Internet Gateway ────────────┘              │
└────────────────────────────────────────────-─┘
         │
   ┌─────▼─────┐
   │    ECR    │  (FastAPI Dummy Image)
   └───────────┘
```

Explanation of the components in the order in which the components actually engage with each other when a task starts.

### 1. Network layer (`vpc.tf`)
**`aws_vpc`** is the isolated network environment for the entire setup. A dedicated VPC instead of the default VPC (clean separation, reproducible via Terraform, not dependent on Floci's automatically seeded default VPC).

**`aws_subnet` (2×, across 2 AZs)** – ECS Fargate services with `awsvpc` networking need at least one subnet per task; two subnets across two AZs are needed so the 2 desired Fargate tasks can actually be distributed across different Availability Zones (multi-AZ redundancy – if one AZ goes down, the second task keeps running).

**`aws_internet_gateway`** – without an IGW, the VPC has no connection to the outside world. Necessary so tasks could (in theory) pull images from real registries, and so `assign_public_ip` has any meaning at all.

**`aws_route_table` + `aws_route_table_association`** – the subnets are only "public" because their route table has a `0.0.0.0/0` entry pointing to the IGW. Without this route they would technically be private subnets, regardless of what `map_public_ip_on_launch` says.

→ **How they interact:** The VPC is the container for everything else; subnets + route table + IGW together produce "public reachability." The ECS service later references exactly these subnet IDs in its `network_configuration`.

### 2. Image management (`ecr.tf`)

**`aws_ecr_repository`** is the storage location for the FastAPI image. It exists independently of ECS/VPC – ECR is a standalone service that's only linked to the task definition via the image URI (`${aws_ecr_repository.app.repository_url}:${var.container_image_tag}`). That's also why we could create it first using `-target`: no dependency on VPC or IAM.

### 3. Identity & permissions (`iam.tf`)

**`aws_iam_role.ecs_execution_role`** is assumed by the **ECS infrastructure itself** (not by the application code) in order to *start* the container: pulling the image from ECR, writing logs to CloudWatch. Hence the `AmazonECSTaskExecutionRolePolicy`.

**`aws_iam_role.ecs_task_role`** is assumed by the **running container code**, in case the FastAPI service itself were to call AWS APIs (S3, DynamoDB, etc.). Currently without any policy, since the dummy service doesn't do anything like that – but deliberately set up as a separate role so we can later add permissions for the application code without loosening the execution permissions (principle of least privilege: two roles instead of one "do-everything" role).

Both roles trust the same trust-relationship document (`ecs-tasks.amazonaws.com` is allowed to assume them) – that's the standard mechanism through which ECS is authorized to act on behalf of these roles in the first place.

### 4. Compute layer (`ecs.tf`)

**`aws_ecs_cluster`** is initially just a logical namespace/grouping – with Fargate (unlike the EC2 launch type), the cluster doesn't manage its own servers, it only groups services/tasks.

**`aws_cloudwatch_log_group`** exists *before* the task definition, because the task definition's `logConfiguration` block already references the log group's name – the order matters here (Terraform resolves this correctly and automatically via the resource reference).

**`aws_ecs_task_definition`** is the actual "blueprint": which image, how much CPU/memory, which port, which two IAM roles, where the logs go. `requires_compatibilities = ["FARGATE"]` + `network_mode = "awsvpc"` are not arbitrary here, but a mandatory combination – Fargate *requires* `awsvpc` networking (unlike the EC2 launch type, which also allows `bridge`/`host`).

**`aws_ecs_service`** is the component that ensures the task definition is actually kept running persistently (`desired_count = 2`) – if a task dies, the service automatically starts a new one. The `network_configuration` block is the bridge to the network layer: it tells the service which subnets (from `vpc.tf`) and which security group the tasks should get their ENI from.

**`aws_security_group`** acts directly on this ENI (Elastic Network Interface) – it's the firewall layer between "the internet" and the container, not between "the VPC" and the container. Inbound only port 8000 (the FastAPI port), outbound everything (so that the execution-role mechanism for ECR pulls and CloudWatch logs works – both technically run over egress traffic).

### 5. Outputs (`outputs.tf`)

Pure convenience layer: the ECR URL, cluster/service name, and VPC/subnet IDs are exported so the README workflow commands (pushing the image, updating the service, inspecting tasks) can pick them up via `terraform output` instead of hardcoding them.

### How it all comes together

When we run `terraform apply` and the service spins up, roughly the following happens:

1. The ECS service sees: "I'm supposed to have 2 tasks of the current task definition running"
2. For each task: ECS uses the **execution role** to pull the image from the **ECR URL** referenced in the task definition
3. ECS creates a network interface in one of the two **subnets** (round-robin across the AZs) and attaches the **security group** to it
4. The container starts with the **task role** for its own API calls (unused here) and writes logs to the **CloudWatch log group** (again via the execution role)
5. Since the subnet + route table + IGW form a public route and `assign_public_ip = true` is set, the task would be assigned a public IP in real AWS

Each component therefore has a clearly scoped responsibility (network / identity / image / runtime definition / runtime control).


## Production Setup
Using two public subnets works fine for local testing, but is not
suitable for production for several reasons:

- **Direct internet exposure** – every Fargate task gets its own public
IP with `assign_public_ip = true`, protected only by a security group.
A single misconfiguration exposes the container directly to the
internet, with no additional layer (WAF, ALB) to catch it.

- **No central control point** – without an ALB or API Gateway in front,
there's no central place for TLS termination, WAF, rate limiting, DDoS
protection, or consistent access logging.

- **Cost** – AWS charges for every public IPv4
address. With Auto Scaling, this cost grows
linearly with every new task, whereas an ALB only ever needs 1-2 public
IPs regardless of how many tasks run behind it.

- **No load balancing, no stable address** – each task has its own IP
that changes on every restart. Without an ALB there's no stable DNS
address, no traffic distribution across tasks, and no health checks to
remove a failing task from rotation.

- **Deployments & compliance** – rolling updates and blue/green
deployments require ALB target group health checks and connection
draining to work cleanly.

This requires adding private subnets, a NAT Gateway (costs) or VPC Endpoint (no costs for aws internal services), `aws_lb`, `aws_lb_target_group`, and `aws_lb_listener`.

The NAT Gateway sits in the public subnet and handles exclusively outbound (egress) traffic from the private subnets — not inbound. Tasks in private subnets have no public IP of their own, so the NAT Gateway masquerades their private IP as its own public IP when they need to reach the internet (e.g. for ECR pulls, CloudWatch logs, or external APIs).
As an alternative, VPC Endpoints (PrivateLink) route traffic to AWS-internal services like ECR and CloudWatch directly over the internal AWS network — no NAT Gateway needed for those cases. For third-party APIs, a NAT Gateway remains necessary.

