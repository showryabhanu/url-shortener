# URL Shortener on AWS Learner Lab

A production-grade, URL shortener built for AWS Learner Lab running on Amazon Linux 2023, Node.js 20, Amazon DynamoDB, and Caddy reverse proxy with automatic Let's Encrypt HTTPS.

---

## Architecture Overview

```
                                      Internet
                                         │
                                         ▼
                                 [ cc7.duckdns.org ]
                                         │
                          ┌──────────────┴──────────────┐
                          │    Elastic IP (Public IP)    │
                          └──────────────┬──────────────┘
                                         │ Ports 80 & 443
                                         ▼
                 ┌────────────────────────────────────────────────┐
                 │       EC2 Instance (Amazon Linux 2023)        │
                 │                   t3.micro                     │
                 │                                                │
                 │   ┌────────────────────────────────────────┐   │
                 │   │     Caddy Web Server (Reverse Proxy)   │   │
                 │   │   - Automatic Let's Encrypt TLS (443)  │   │
                 │   │   - HTTP to HTTPS Redirect (80 -> 443) │   │
                 │   └───────────────────┬────────────────────┘   │
                 │                       │ localhost:3000         │
                 │                       ▼                        │
                 │   ┌────────────────────────────────────────┐   │
                 │   │      Node.js 20 Express Service        │   │
                 │   │   - Systemd Service (auto-restart)     │   │
                 │   │   - Base62 Collision Retries           │   │
                 │   │   - Strict Length Savings Validation   │   │
                 │   │   - In-memory IP Rate Limiting         │   │
                 │   └───────────────────┬────────────────────┘   │
                 └───────────────────────┼────────────────────────┘
                                         │ AWS SDK v3
                                         │ IAM: LabInstanceProfile
                                         ▼
                            ┌─────────────────────────┐
                            │ DynamoDB: `short_links` │
                            │   - On-Demand (PAY_REQ) │
                            │   - PK: code (String)   │
                            │   - Atomic Clicks Counter│
                            └─────────────────────────┘
```

---

## Directory Structure

```
url-shortener/
├── app/
│   ├── package.json          # Node.js dependencies (Express, AWS SDK v3)
│   ├── server.js             # Core API & redirect engine
│   └── public/
│       └── index.html        # Clean, dependency-free responsive UI
├── infra/
│   ├── create-table.sh       # Provisions DynamoDB table with on-demand capacity
│   ├── create-network.sh     # Configures VPC, Subnet, Security Group & Key Pair
│   ├── launch-ec2.sh         # Finds AL2023 AMI, launches EC2 & associates Elastic IP
│   ├── deploy.sh             # Packages app, configures Node 20, systemd & Caddy
│   └── teardown.sh           # Fully removes all provisioned AWS resources
├── .env.example              # Template configuration
├── .env                      # Local configuration (domain, table, region)
├── .gitignore
└── README.md
```

---

## Prerequisites

1. **AWS CLI v2** configured locally with active Learner Lab credentials (`~/.aws/credentials`).
2. **DuckDNS or Custom Domain**: A domain pointing to the allocated Elastic IP (e.g. `cc7.duckdns.org`).
3. **Region**: `us-east-1` (mandatory for AWS Learner Lab).

---

## Step-by-Step Deployment Guide

### 1. Configure Environment
Verify `.env` has your desired domain:
```bash
SHORT_DOMAIN=cc7.duckdns.org
AWS_REGION=us-east-1
TABLE_NAME=short_links
PORT=3000
REDIRECT_STATUS=302
```

### 2. Create DynamoDB Table
```bash
chmod +x infra/*.sh
./infra/create-table.sh
```

### 3. Configure Security Group and Key Pair
```bash
./infra/create-network.sh
```
- Restricts SSH (port 22) to your detected current public IP.
- Opens HTTP (port 80) and HTTPS (port 443) to the internet.
- Generates SSH key `~/.ssh/url-shortener-key.pem` with `chmod 400`.

### 4. Launch EC2 Instance & Elastic IP
```bash
./infra/launch-ec2.sh
```
- Dynamically queries the latest AL2023 AMI via SSM.
- Launches a `t3.micro` instance with pre-configured `LabInstanceProfile`.
- Allocates and attaches an Elastic IP.

### 5. Update DNS A Record
Take the Elastic IP printed by `launch-ec2.sh` and update your DNS record:
- **Type**: `A`
- **Domain**: `cc7.duckdns.org`
- **Value**: `<Elastic IP>`

Verify DNS propagation:
```bash
dig +short cc7.duckdns.org
```

### 6. Deploy Application & Caddy
Once DNS resolves to your Elastic IP:
```bash
./infra/deploy.sh
```
This transfers the code, installs Node.js 20 and Caddy, establishes systemd auto-restart services, and provisions automatic Let's Encrypt certificates.

---

## Verification & API Endpoints

### 1. Health Check
```bash
curl -i https://cc7.duckdns.org/health
```

### 2. Shorten URL (`POST /api/shorten`)
```bash
curl -i -X POST https://cc7.duckdns.org/api/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html"}'
```

### 3. Strict Length Rule Violation (422)
```bash
curl -i -X POST https://cc7.duckdns.org/api/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://short.me"}'
```
Returns `422 Unprocessable Entity` because the short link would be longer than or equal to the original URL.

### 4. Custom Alias
```bash
curl -i -X POST https://cc7.duckdns.org/api/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://aws.amazon.com/dynamodb/", "alias": "dynamo-docs"}'
```

### 5. Test Redirect & Click Increment
```bash
curl -I https://cc7.duckdns.org/dynamo-docs
```
Returns `HTTP/2 302 Found` with `Location: https://aws.amazon.com/dynamodb/` and increments the click counter in DynamoDB.

---

## Learner Lab Session Restart Runbook

In AWS Learner Lab, sessions automatically expire after 4 hours, and the EC2 instance stops.

When you start a new lab session:
1. **Credentials**: Update `~/.aws/credentials` with the new temporary session token from the Learner Lab console.
2. **Persistence**:
   - The **DynamoDB table** persists intact with all links and click analytics.
   - The **Elastic IP** remains associated with your instance, meaning **you do NOT need to update DNS**.
3. **Restart Instance**:
   Run:
   ```bash
   aws ec2 start-instances --instance-ids $(cat .infra_state | grep INSTANCE_ID | cut -d'=' -f2) --region us-east-1
   ```
4. **Auto-Recovery**:
   - Both `url-shortener.service` and `caddy.service` are enabled as systemd services with `Restart=always`.
   - As soon as the instance boots, Caddy and Express automatically start.
   - Check status:
     ```bash
     curl -i https://cc7.duckdns.org/health
     ```

---

## Complete Teardown

To release all resources and avoid unwanted charges:
```bash
./infra/teardown.sh
```
This terminates the EC2 instance, releases the Elastic IP, removes the security group, deletes the key pair, and removes the DynamoDB table.
