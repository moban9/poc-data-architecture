# GCP Infrastructure — Manual Setup Runbook

Operator runbook for bringing up the GCP side of the POC by hand, in the order a
human actually does it. Every resource name, variable, port, and command below is
taken verbatim from `terraform/gcp/**`, `.github/workflows/*.yml`, `Makefile`, and
`scripts/bootstrap.sh`. Where the repo does **not** define something (WIF IAM
bindings, DNS records), this doc says so instead of inventing it.

The GCP stack is one app VM (`e2-standard-8`) in a private subnet, reachable only
through an external HTTPS load balancer (managed TLS + Cloud Armor) and SSH, with
a Docker stack started afterward by `make deploy`.

---

## 1. Prerequisites

**Proves:** you have a billing-enabled GCP project, the right CLI tooling, and a
pinned Terraform provider before touching anything.

- **gcloud SDK** — `gcloud --version` (any recent SDK; workflows use
  `google-github-actions/setup-gcloud@v2`).
- **Terraform** — pin lives in `terraform/gcp/main.tf` (there is **no**
  `versions.tf`):
  - `required_version = ">= 1.5"`
  - provider `hashicorp/google` `~> 6.0`, locked to **6.50.0** in
    `terraform/gcp/.terraform.lock.hcl`.
- **Required APIs** — Compute Engine API and Service Usage API. The service
  account used for apply must hold **Compute Admin** and **Service Usage Admin**
  (stated in the `terraform/gcp/main.tf` provider comment). Enable per command:
  ```bash
  gcloud services enable compute.googleapis.com serviceusage.googleapis.com
  ```
- **Auth** — one of (from the `terraform/gcp/main.tf` provider comment):
  ```bash
  # Option A — service-account JSON key (Compute Admin + Service Usage Admin)
  export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json

  # Option B — user credentials via application-default login
  gcloud auth application-default login
  ```

---

## 2. Project + state

**Proves:** the values in `terraform.tfvars` match what Terraform will actually
deploy, and you know where state lives.

Real variable names (from `terraform/gcp/variables.tf`) and the values in
`terraform/gcp/terraform.tfvars.example`:

| Variable | Default (variables.tf) | tfvars.example | Meaning |
|---|---|---|---|
| `project_id` | *(required)* | `your-gcp-project-id` | GCP project ID |
| `name` | `lms-poc` | `lms-poc` | resource prefix (`${name}-vm`) |
| `region` | `asia-southeast2` | `asia-southeast2` | region for VPC/LB/VM |
| `zone` | `asia-southeast2-a` | `asia-southeast2-a` | zone for VM + instance group |
| `machine_type` | `e2-standard-8` | `e2-standard-8` | 8 vCPU / 32 GB |
| `boot_disk_gb` | `100` | `100` | boot disk size |
| `cert_domain` | `onendo.cloud` | `app.example.com` | base domain for managed cert |
| `vpc_name` | `poc-vpc` | *(default)* | VPC name |
| `vpc_cidr` | `10.0.0.0/16` | *(default)* | VPC CIDR |
| `public_subnet_cidr` | `10.0.0.0/24` | *(default)* | `sn-public` |
| `private_subnet_cidr` | `10.0.1.0/24` | *(default)* | `sn-private` |
| `proxy_subnet_cidr` | `10.0.2.0/24` | *(default)* | `sn-proxy` |
| `app_port` | `80` | *(default)* | Traefik/backend/health-check port |
| `lb_ingress_ports` | `["80","443"]` | *(default)* | LB→app firewall ports |
| `app_tag` | `app` | *(default)* | firewall network tag |
| `enable_cloud_armor` | `true` | *(default)* | attach Cloud Armor policy |

Notes that will save you time:

- **There is no SSH CIDR variable on GCP.** The AWS side has `allowed_ssh_cidrs`,
  but GCP's public-SSH firewall is hardcoded to `0.0.0.0/0` (see §4). Tighten it
  by editing `terraform/gcp/network/main.tf` before apply.
- **State is local.** No `backend "gcs"` block exists anywhere in `terraform/gcp/`,
  so `terraform.tfstate` lives in `terraform/gcp/`. Run all Terraform commands from
  that directory (or use the Makefile targets) so state is not lost.

Create your var file:

```bash
cd terraform/gcp
cp terraform.tfvars.example terraform.tfvars
# edit: project_id, cert_domain (a domain you actually control)
```

---

## 3. Workload Identity Federation

**Proves:** CI can authenticate to GCP without a long-lived key — **and** that the
WIF wiring is *not* in this repo (it must exist before CI runs).

The `.tf` files contain **no** `google_iam_workload_identity_pool` /
`..._provider` / IAM-binding resources and no GitHub repo/branch attribute
condition. WIF is configured outside Terraform. The only WIF identifiers present
in the repo are the ones the GitHub workflows hardcode:

- **Pool:** `hermes-poc-pool`
- **Provider:** `hermes-oidc` (full path
  `projects/445642900277/locations/global/workloadIdentityPools/hermes-poc-pool/providers/hermes-oidc`)
- **Project number:** `445642900277`
- **Service account:** `hermes-poc@project-955f419f-217d-449b-950.iam.gserviceaccount.com`
- **Project ID:** `project-955f419f-217d-449b-950`

The exact IAM role bindings on that service account and the OIDC attribute
condition (GitHub repo/branch) are **not stored in this repo** — they live in the
GCP project. The repo's only statement about required roles is the
`terraform/gcp/main.tf` provider comment: **Compute Admin + Service Usage Admin**.

For a from-scratch setup, create these to match the workflow paths exactly
(gcloud-side, outside Terraform):

```bash
gcloud iam workload-identity-pools create hermes-poc-pool \
  --location="global" --project="445642900277"

gcloud iam workload-identity-pools providers create-oidc hermes-oidc \
  --location="global" --project="445642900277" \
  --workload-identity-pool="hermes-poc-pool" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='<owner>/<repo>'"
```

Then grant the service account `hermes-poc@…iam.gserviceaccount.com` the roles
needed to apply Terraform (Compute Admin + Service Usage Admin) and bind the
principal set to the pool provider. Match the provider path and service-account
email byte-for-byte with the workflows in §5.

---

## 4. Terraform apply

**Proves:** `plan`/`apply` create the full network + LB + VM, and you know each
resource by name and purpose.

Run from `terraform/gcp/` (or use `make init plan apply`):

```bash
cd terraform/gcp
terraform init
terraform plan
terraform apply -auto-approve
```

What `apply` creates — resource name in the `.tf` (network resources live in
`terraform/gcp/network/main.tf`) → one-line purpose:

**VM & image (root `terraform/gcp/main.tf`)**

| Resource | Real name | Purpose |
|---|---|---|
| `data.google_compute_image.ubuntu` | family `ubuntu-2204-lts` (project `ubuntu-os-cloud`) | Ubuntu 22.04 LTS boot image |
| `google_compute_instance.poc` | `lms-poc-vm` | the single POC node — `e2-standard-8`, 100 GB `pd-balanced`, private subnet + ephemeral public IP (deploy-SSH only), runs `scripts/bootstrap.sh` on first boot, ssh-key `ubuntu:ssh-ed25519 … poc-deploy`, tags `[app]`, scope `cloud-platform` |

**Network (`terraform/gcp/network/main.tf`)**

| Resource | Real name | Purpose |
|---|---|---|
| `google_compute_network.vpc` | `poc-vpc` | VPC, `auto_create_subnetworks=false`, `REGIONAL` routing |
| `google_compute_subnetwork.public` | `sn-public` (10.0.0.0/24) | egress-only subnet (Cloud NAT) |
| `google_compute_subnetwork.private` | `sn-private` (10.0.1.0/24) | app VM subnet (no public IP) |
| `google_compute_subnetwork.proxy` | `sn-proxy` (10.0.2.0/24) | proxy-only subnet, `REGIONAL_MANAGED_PROXY` |
| `google_compute_router.router` | `poc-vpc-router` | Cloud Router for NAT |
| `google_compute_router_nat.nat` | `poc-vpc-nat` | Cloud NAT (`AUTO_ONLY`) for `sn-private` outbound |
| `google_compute_firewall.allow_lb` | `poc-vpc-allow-lb` | tcp 80/443 from `35.191.0.0/16`,`130.211.0.0/22` (LB proxy + health checks) → tag `app` |
| `google_compute_firewall.allow_iap_ssh` | `poc-vpc-allow-iap-ssh` | tcp 22 from `35.235.240.0/20` (IAP) |
| `google_compute_firewall.allow_ssh_public` | `poc-vpc-allow-ssh-public` | tcp 22 from `0.0.0.0/0` — **tighten before anything longer than a day** |
| `google_compute_firewall.allow_internal` | `poc-vpc-allow-internal` | tcp/udp 0-65535 + icmp from `10.0.0.0/16` (service-to-service) |
| `google_compute_firewall.deny_all_ingress` | `poc-vpc-deny-all-ingress` | default-deny INGRESS, priority `65534` |
| `google_compute_security_policy.armor` | `poc-vpc-armor` | Cloud Armor, default allow-all (count = `enable_cloud_armor`) |

**Load balancer + cert (`terraform/gcp/network/main.tf`)**

| Resource | Real name | Purpose |
|---|---|---|
| `google_compute_global_address.lb_ip` | `poc-vpc-lb-ip` | global static IP for the LB |
| `google_compute_instance_group.app` | `poc-vpc-app-ig` | unmanaged IG; named port `https`→`80` |
| `google_compute_health_check.app` | `poc-vpc-health-check` | TCP health check on port `80` |
| `google_compute_backend_service.app` | `poc-vpc-backend` | HTTP backend, `poc-vpc-armor` security policy |
| `google_compute_url_map.app` | `poc-vpc-url-map` | default service → backend |
| `google_compute_managed_ssl_certificate.cert` | `poc-vpc-managed-cert` | 12 SANs: `grafana`,`demo`,`bi`,`plane`,`trino`,`polaris`,`minio`,`connect`,`lms`,`prometheus`,`alertmanager`,`pushgateway`.`<cert_domain>` |
| `google_compute_target_https_proxy.proxy` | `poc-vpc-https-proxy` | HTTPS proxy → url-map, cert |
| `google_compute_global_forwarding_rule.https` | `poc-vpc-https-forwarding-rule` | TCP 443 → proxy |

**DNS is manual — not in Terraform.** There are no `google_dns_*` resources. After
apply, create **A records** for all 12 subdomains above pointing at the LB IP
(see the `cert_domain` description in `terraform/gcp/variables.tf`). Until DNS
resolves, `poc-vpc-managed-cert` stays `PROVISIONING`.

**Outputs** (root `terraform/gcp/main.tf`): `load_balancer_ip`,
`instance_public_ip`, `instance_private_ip`.

---

## 5. GitHub Actions wiring

**Proves:** what triggers each workflow and that no custom secrets are required —
the WIF identifiers are hardcoded in the YAML.

**Required secrets/vars: none.** Every workflow hardcodes the WIF provider path,
service account, project ID, zone, and VM name inline. The only token used is the
built-in `GITHUB_TOKEN` (`${{ github.token }}`, in `deploy.yml` for the
`git clone https://x-access-token:${GITHUB_TOKEN}@github.com/<owner>/<repo>.git`
step). All workflows are `workflow_dispatch` only — trigger manually from
**Actions → <workflow> → Run workflow**:

| Workflow | Permissions | What it does |
|---|---|---|
| `terraform-apply.yml` | `contents: read`, `id-token: write` | `checkout@v4` → `setup-terraform@v3` → `google-github-actions/auth@v2` (WIF) → `setup-gcloud@v2` → `terraform init && terraform apply -auto-approve` with `TF_VAR_project_id`/`region`/`zone` env |
| `deploy.yml` | `contents: read`, `id-token: write`, `issues: write` | `validate` (fmt+validate, `docker compose config -q`) → `deploy` (terraform apply, SSH clone + `docker compose up -d`, report LB IP + endpoints, open `[INCIDENT]` issue on failure) |
| `vm-remote-exec.yml` | `contents: read`, `id-token: write` | runs one shell `command` (input) via `gcloud compute ssh ubuntu@lms-poc-vm` |
| `vm-control.yml` | `contents: read`, `id-token: write` | `start`/`stop` (choice input) `lms-poc-vm`; on `start` prints `natIP` |
| `auth-test.yml` | `contents: read`, `id-token: write` | read-only WIF check: `gcloud auth list --filter=status:ACTIVE` |
| `cert-status.yml` | `contents: read`, `id-token: write` | `gcloud compute ssl-certificates list` + describe `poc-vpc-managed-cert` |

The `id-token: write` permission on every workflow is what lets
`google-github-actions/auth@v2` mint the OIDC token for WIF (noted in
`auth-test.yml`). Without it, GCP auth fails.

---

## 6. Verification

**Proves:** each layer (VM, LB, cert, backend health) is actually live.

```bash
cd terraform/gcp

# LB IP — point the 12 DNS A records here
terraform output load_balancer_ip
# ephemeral deploy-SSH IP + private IP
terraform output instance_public_ip
terraform output instance_private_ip

# VM is RUNNING with the right shape
gcloud compute instances describe lms-poc-vm --zone asia-southeast2-a \
  --format="value(status, machineType, networkInterfaces[0].accessConfigs[0].natIP)"

# managed cert no longer PROVISIONING (needs DNS first)
gcloud compute ssl-certificates describe poc-vpc-managed-cert \
  --format="json(managed.status, managed.domainStatus)"

# LB backend actually healthy (instance group reports HEALTHY)
gcloud compute backend-services get-health poc-vpc-backend --global

# HTTPS LB forwarding rule active
gcloud compute forwarding-rules list --format="value(name,IPAddress,IPProtocol,portRange)"
```

After DNS + cert provisioning, hit the public endpoints (from `deploy.yml`):

```bash
curl -sI https://grafana.<cert_domain>
curl -sI https://demo.<cert_domain>
```

SSH to the node (user is `ubuntu`):

```bash
# public IP (deploy path, firewall-restricted)
ssh ubuntu@$(terraform output -raw instance_public_ip)

# or via IAP (private IP path, `poc-vpc-allow-iap-ssh`)
gcloud compute ssh ubuntu@lms-poc-vm --zone asia-southeast2-a --tunnel-through-iap
```

---

## 7. Teardown + cost

**Proves:** how to stop the meter and what it costs while it runs.

```bash
make teardown   # = cd terraform/gcp && terraform destroy -auto-approve
```

Destroy deletes the VM, boot disk, firewall, LB, and cert (state is local, so
`terraform destroy` from the same `terraform/gcp/` directory).

Cost (matches `README.md` and `docs/examples.md`):

| Item | Rate | 1-day |
|---|---|---|
| `e2-standard-8` (8 vCPU/32 GB) | $0.268/hr | $6.43 |
| 100 GB `pd-balanced` | $4/mo | ≈$0.13 |
| **Total** | | **≈$6.60 (~$7/day)** |

- ~2–3% of the $300 free-trial credit.
- Trial caps Compute Engine at **8 concurrent cores** — this VM is exactly 8.
- **Delete (not stop) after the run** — the boot disk bills while the VM is
  stopped.

---

## 8. Troubleshooting

**Proves:** the failure modes that are actually visible in the code, and where to
look for each.

- **SSH user is `ubuntu`, not root** — `metadata.ssh-keys` in
  `terraform/gcp/main.tf` installs a key for `ubuntu`; `scripts/bootstrap.sh` runs
  `usermod -aG docker ubuntu`; `Makefile` and `deploy.yml` both SSH as
  `ubuntu@…`. Keying as `root` fails.
- **WIF auth fails in CI** — check the workflow has `permissions.id-token: write`
  (it's what mints the OIDC token, per `auth-test.yml`), and that the
  `workload_identity_provider` path + `service_account` email match the GCP-side
  pool/provider/SA **exactly** (they're hardcoded, not secrets). Run `auth-test`
  to isolate auth from deploy.
- **Cert stuck `PROVISIONING`** — the managed cert needs all 12 A records
  (`grafana`/`demo`/`bi`/`plane`/`trino`/`polaris`/`minio`/`connect`/`lms`/
  `prometheus`/`alertmanager`/`pushgateway` `. <cert_domain>`) pointed at the LB IP
  (`terraform output load_balancer_ip`). Check with `cert-status` or the
  `gcloud` command in §6. Provisioning typically takes several minutes to hours.
- **LB health check failing** — backend expects Traefik on **port 80**
  (`app_port`, IG named port `https`→`80`). If the Docker stack isn't up yet
  (`make deploy` / `deploy.yml` start it *after* apply), the backend stays
  unhealthy.
- **SSH from the internet is wide open** — `google_compute_firewall.allow_ssh_public`
  (`poc-vpc-allow-ssh-public`) allows `0.0.0.0/0` on 22 by design for CI. Tighten
  it before any run longer than a day.
- **"VM has no public IP" but it does** — the comment in `terraform/gcp/main.tf`
  says "NO public IP", yet `network_interface.access_config` attaches an ephemeral
  NAT IP. That IP is the *deploy SSH* endpoint (`instance_public_ip`, used by
  `Makefile`), **not** the app endpoint; app traffic flows through the LB.
- **`make deploy` can't find the VM IP** — `IP` is derived from
  `terraform output -raw instance_public_ip`, which is empty until
  `terraform apply` has run at least once in `terraform/gcp/`.

---

Produced by: Nimbus · Reviewed by: Ledger
