# One-time setup

Everything here is run **once**, by a human, from a machine with `gcloud` and
`gh` installed and authenticated. After this, pushes/PRs to this repo do all
the work.

## Staying inside GCP's Always Free tier

This repo's defaults (`terraform/variables.tf`) target Compute Engine's
Always Free allowance:

- **`e2-micro`**, and only in **`us-west1`, `us-central1`, or `us-east1`**
  (default: `us-central1`) — any other machine type or region is billed
  normally.
- **One `pd-standard` boot disk up to 30 GB** — `pd-balanced`/`pd-ssd` are
  never free, at any size.
- **One free instance per billing account**, not per project — if you (or
  anything else on this billing account) already runs a free-tier VM
  elsewhere, this one will be billed too.
- The static IP is free *while attached to a running instance*. If you ever
  stop the instance without releasing the IP, GCP starts charging for the
  now-idle reservation.
- Network egress: ~1 GB/month to most destinations is free; a VPN
  relaying real traffic can exceed that fairly easily — check the Billing
  page after the first month rather than assuming it's zero.
- `e2-micro` has 1 GB RAM. The playbook adds a 2 GB swapfile as headroom for
  Docker + Headplane, but this is not a machine with slack to spare — expect
  to upsize to `e2-small`/`e2-medium` (both billed) if the tailnet grows.

## 0. Fill in these values

```bash
export PROJECT_ID="your-gcp-project-id"        # must not already exist, or already be yours
export BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"  # gcloud billing accounts list
export REPO="conway-hash/headscale-coordination-server-vpn" # GitHub owner/repo
export DOMAIN="vpn.conway-hash.com"            # public hostname Caddy serves
export REGION="us-central1"                    # Always Free tier: us-west1 | us-central1 | us-east1 only
export ZONE="us-central1-a"
export SA_NAME="gh-actions-deployer"
export POOL_ID="github-pool"
export PROVIDER_ID="github-provider"
```

## 1. Create the GCP project and enable APIs

```bash
gcloud projects create "$PROJECT_ID"
gcloud beta billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"

gcloud services enable \
  compute.googleapis.com \
  iamcredentials.googleapis.com \
  iam.googleapis.com \
  sts.googleapis.com \
  storage.googleapis.com \
  --project "$PROJECT_ID"
```

## 2. Create the OpenTofu state bucket

```bash
gsutil mb -l EU -b on "gs://${PROJECT_ID}-tofu-state"
gsutil versioning set on "gs://${PROJECT_ID}-tofu-state"
```

## 3. Create the deployer service account

This is the identity GitHub Actions assumes. It gets only what it needs to
manage this VM's network/compute resources and to tunnel SSH through IAP —
nothing account-wide.

```bash
gcloud iam service-accounts create "$SA_NAME" \
  --project "$PROJECT_ID" \
  --display-name "GitHub Actions deployer"

export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

for ROLE in roles/compute.instanceAdmin.v1 roles/compute.networkAdmin \
            roles/compute.securityAdmin roles/iam.serviceAccountUser \
            roles/iap.tunnelResourceAccessor; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" --condition=None
done

gsutil iam ch "serviceAccount:${SA_EMAIL}:roles/storage.objectAdmin" \
  "gs://${PROJECT_ID}-tofu-state"
```

## 4. Workload Identity Federation (no long-lived key ever leaves GCP)

```bash
gcloud iam workload-identity-pools create "$POOL_ID" \
  --project="$PROJECT_ID" --location="global" \
  --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
  --project="$PROJECT_ID" --location="global" \
  --workload-identity-pool="$POOL_ID" \
  --display-name="GitHub" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${REPO}'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

export WIF_POOL=$(gcloud iam workload-identity-pools describe "$POOL_ID" \
  --project="$PROJECT_ID" --location=global --format="value(name)")

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${WIF_POOL}/attribute.repository/${REPO}"

echo "GCP_WORKLOAD_IDENTITY_PROVIDER = ${WIF_POOL}/providers/${PROVIDER_ID}"
echo "GCP_SERVICE_ACCOUNT_EMAIL      = ${SA_EMAIL}"
```

The `--attribute-condition` above pins this exactly to `$REPO` — no other
repository can ever assume this identity, even if it also uses GitHub's OIDC
issuer.

## 5. SSH keypair for Ansible (goes over the IAP tunnel, never a public port)

```bash
ssh-keygen -t ed25519 -f ./deploy_key -N "" -C "gh-actions-ansible"
```

## 6. Google OAuth client — used by TWO separate login flows

This one client covers both:

- **Headscale's own OIDC** — lets `tailscale up --login-server=https://$DOMAIN`
  authenticate a device via Google SSO instead of a pre-auth key.
- **Headplane's OIDC** — lets you log into the admin UI at `/admin`.

Console → **APIs & Services → Credentials → Create Credentials → OAuth client
ID** → Application type "Web application". Add **both** authorized redirect
URIs to it:

- `https://${DOMAIN}/oidc/callback` (headscale — fixed path, not configurable)
- `https://${DOMAIN}/admin/oidc/callback` (headplane — double-check this one
  against the Headplane version you're running; it logs the redirect URI it
  expects on its first OIDC attempt if this is wrong)

Note the generated **Client ID** and **Client secret**.

**Also decide who's allowed to join the tailnet.** Without this, any Google
account on the internet could authenticate a device against your headscale
server — the playbook refuses to deploy if it's empty, on purpose.

```bash
export ALLOWED_USERS="you@gmail.com"   # comma-separated if more than one
```

## 7. Push everything into GitHub secrets/variables

```bash
gh secret set GCP_PROJECT_ID                --body "$PROJECT_ID" -R "$REPO"
gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --body "${WIF_POOL}/providers/${PROVIDER_ID}" -R "$REPO"
gh secret set GCP_SERVICE_ACCOUNT_EMAIL      --body "$SA_EMAIL" -R "$REPO"
gh secret set TF_STATE_BUCKET                --body "${PROJECT_ID}-tofu-state" -R "$REPO"
gh secret set SSH_PUBLIC_KEY                 --body "$(cat deploy_key.pub)" -R "$REPO"
gh secret set SSH_PRIVATE_KEY                --body "$(cat deploy_key)" -R "$REPO"
gh secret set GOOGLE_OIDC_CLIENT_ID          --body "PASTE_CLIENT_ID" -R "$REPO"
gh secret set GOOGLE_OIDC_CLIENT_SECRET      --body "PASTE_CLIENT_SECRET" -R "$REPO"

gh variable set GCP_REGION                 --body "$REGION" -R "$REPO"
gh variable set GCP_ZONE                   --body "$ZONE" -R "$REPO"
gh variable set INSTANCE_NAME              --body "coordination-server" -R "$REPO"
gh variable set MACHINE_TYPE               --body "e2-micro" -R "$REPO"
gh variable set DOMAIN                     --body "$DOMAIN" -R "$REPO"
gh variable set HEADSCALE_ALLOWED_OIDC_USERS --body "$ALLOWED_USERS" -R "$REPO"
```

Now delete `deploy_key` and `deploy_key.pub` from your local disk — they're
in GitHub Secrets now and don't need to exist anywhere else.

## 8. First run

1. Open a PR touching anything under `terraform/` (or just push a no-op
   change) → the **OpenTofu Plan** workflow runs and comments the plan.
2. Merge to `main` → **Deploy Coordination Server** applies the infra, then
   runs the Ansible playbook against the new VM.
3. Take the `external_ip` from the tofu output (or the GCP Console) and point
   `$DOMAIN`'s DNS **A record** at it. Caddy retries ACME issuance until the
   record resolves, so it's fine to apply first and add DNS a few minutes
   later.
4. Visit `https://$DOMAIN/admin` and log in via Google OIDC.
5. Join a device: `tailscale up --login-server=https://$DOMAIN` — it opens a
   browser for the same Google login, checked against
   `HEADSCALE_ALLOWED_OIDC_USERS`.

## Rotating things

- **Headscale API key**: SSH in (`gcloud compute ssh coordination-server
  --tunnel-through-iap --zone=$ZONE`), delete
  `/opt/coordination-stack/headplane/.api_key`, re-run the `deploy` workflow.
- **Headplane cookie secret**: same idea, delete `.cookie_secret` instead —
  this invalidates existing Headplane sessions.
- **Google OIDC client secret**: rotate in Google Cloud Console, then
  `gh secret set GOOGLE_OIDC_CLIENT_SECRET --body "NEW_VALUE" -R "$REPO"` and
  re-run the deploy workflow.
