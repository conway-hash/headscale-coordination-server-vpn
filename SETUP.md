# One-time setup

Everything here is run **once**, by a human, from a machine with `gcloud` and
`gh` installed and authenticated. After this, pushes/PRs to this repo do all
the work.

## 0. Fill in these values

```bash
export PROJECT_ID="your-gcp-project-id"        # must not already exist, or already be yours
export BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"  # gcloud billing accounts list
export REPO="conway-hash/hscs-infra"           # GitHub owner/repo
export DOMAIN="vpn.conway-hash.com"            # public hostname Caddy serves
export REGION="europe-west1"
export ZONE="europe-west1-b"
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

## 6. Google OAuth client for Headplane login

Console → **APIs & Services → Credentials → Create Credentials → OAuth client
ID** → Application type "Web application".

Authorized redirect URI: `https://${DOMAIN}/admin/oidc/callback` — double
check the exact path against the Headplane version you're running (it logs
the redirect URI it expects on its first OIDC attempt if this is wrong).

Note the generated **Client ID** and **Client secret**.

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

gh variable set GCP_REGION    --body "$REGION" -R "$REPO"
gh variable set GCP_ZONE      --body "$ZONE" -R "$REPO"
gh variable set INSTANCE_NAME --body "coordination-server" -R "$REPO"
gh variable set MACHINE_TYPE  --body "e2-small" -R "$REPO"
gh variable set DOMAIN        --body "$DOMAIN" -R "$REPO"
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

## Rotating things

- **Headscale API key**: SSH in (`gcloud compute ssh coordination-server
  --tunnel-through-iap --zone=$ZONE`), delete
  `/opt/coordination-stack/headplane/.api_key`, re-run the `deploy` workflow.
- **Headplane cookie secret**: same idea, delete `.cookie_secret` instead —
  this invalidates existing Headplane sessions.
- **Google OIDC client secret**: rotate in Google Cloud Console, then
  `gh secret set GOOGLE_OIDC_CLIENT_SECRET --body "NEW_VALUE" -R "$REPO"` and
  re-run the deploy workflow.
