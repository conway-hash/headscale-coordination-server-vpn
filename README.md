# headscale-coordination-server-vpn

OpenTofu + Ansible, running from GitHub Actions, that stand up a small GCP VM
and turn it into a self-hosted [Tailscale](https://tailscale.com)-compatible
coordination server: [Headscale](https://github.com/juanfont/headscale) behind
[Caddy](https://caddyserver.com) (automatic TLS), with
[Headplane](https://github.com/tale/headplane) as the admin UI.

- Public endpoint: `https://vpn.conway-hash.com`
- Tailnet device names (MagicDNS): `*.ts.conway-hash.com`

## Architecture

```
                                   ┌─────────────────────────────┐
 tailscale clients ──── 443 ──────▶│  Caddy (auto TLS via ACME)  │
                                   │   /admin*  → headplane:3000 │
                                   │   /*       → headscale:8080 │
                                   └─────────────┬───────────────┘
                                                  │ docker network
                        ┌─────────────────────────┼─────────────────────┐
                        ▼                         ▼
                 headscale (8080)          headplane (3000)
                 sqlite + tailnet          OIDC login (Google) →
                 keys, DERP map            you, into /admin
                 OIDC login (Google) →
                 a device joining
                 via `tailscale up`

 GitHub Actions ──WIF──▶ GCP IAM ──▶ tofu apply (VM, network, firewall)
                 └──IAP tunnel, no public :22──▶ ansible-playbook (docker,
                                                  configs, `docker compose up`)
```

Everything above the VM boundary is provisioned by OpenTofu; everything
inside it (Docker, the three containers, their configs) is configured by
Ansible. Neither is ever run by hand against production — both run from
GitHub Actions.

## Repo layout

```
terraform/            VPC, firewall, static IP, the VM itself, GCS backend
ansible/
  playbook.yml         entrypoint: docker role, then coordination_stack role
  roles/docker/         installs Docker Engine + Compose plugin
  roles/coordination_stack/
    templates/           Caddyfile, docker-compose.yml, headscale + headplane configs
    tasks/main.yml       renders configs, generates secrets on-box, brings the stack up
.github/workflows/
  terraform-plan.yml     PR check: tofu fmt/validate/plan, posted as a PR comment
  deploy.yml             on merge to main: tofu apply, then the Ansible playbook
  ansible-lint.yml       PR check: ansible-lint
SETUP.md               one-time bootstrap: GCP project, WIF, secrets — run once by hand
renovate.json          dependency updates: GitHub Actions, terraform provider,
                       Ansible Galaxy collections, and the pinned headscale/
                       headplane/caddy image versions (see below)
```

## Keeping dependencies current

[Renovate](https://github.com/apps/renovate) (not installed by default — add
it to this repo from the GitHub Marketplace to activate `renovate.json`)
opens PRs for:

- GitHub Actions versions used in `.github/workflows/`
- the `google` provider constraint in `terraform/versions.tf`
- the Ansible Galaxy collections in `ansible/requirements.yml`
- the `headscale_version` / `headplane_version` / `caddy_version` pins in
  `ansible/group_vars/all/vars.yml` (these are read out of the vars file by
  a custom regex rule, since the actual `docker-compose.yml` is a Jinja
  template Renovate can't parse directly)

GitHub's own Dependabot security alerts and automated security fixes are
also on for this repo — that's independent of Renovate and needs no config
file; see repo Settings → Code security.

## How CI/CD works

| Trigger | What runs |
|---|---|
| PR touching `terraform/**` | `tofu fmt -check`, `tofu validate`, `tofu plan` — plan is posted as a PR comment, nothing is applied |
| PR touching `ansible/**` | `ansible-lint` |
| Push to `main` | `tofu apply`, then the Ansible playbook runs against the (possibly new) VM over an IAP SSH tunnel |
| Manual (`workflow_dispatch`) | Re-run `deploy.yml` on demand — e.g. after rotating a secret |

No infrastructure is ever applied from a PR — only a plan. Applying happens
exactly once, on merge to `main`.

## Security choices worth knowing about

- **No long-lived GCP keys anywhere.** GitHub Actions authenticates via
  [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation) —
  GCP trusts GitHub's own OIDC token, scoped to this one repository.
- **SSH has no public listener.** The firewall only allows port 22 from
  Google's [Identity-Aware Proxy](https://cloud.google.com/iap/docs/using-tcp-forwarding)
  range; Ansible reaches the VM through `gcloud compute start-iap-tunnel`,
  authenticated by the same Workload Identity as the rest of the deploy.
- **Shielded VM** (secure boot, vTPM, integrity monitoring) enabled by
  default.
- **The VM's own service account** can write logs/metrics and nothing else —
  it has no standing access to any other GCP API.
- **Runtime secrets never live in this repo.** The Headscale API key and the
  Headplane cookie secret are generated on the box itself on first deploy and
  persisted root-only outside git. The Google OIDC client ID/secret are
  GitHub Secrets, materialized into a gitignored file only inside the CI job
  that needs them.
- **Joining the tailnet requires being on an explicit allowlist.** One Google
  OAuth client backs two separate logins — headscale's own OIDC (a device
  running `tailscale up`) and Headplane's OIDC (you, into `/admin`) — and the
  playbook refuses to deploy at all if `oidc_allowed_users` is empty. Without
  that check, anyone with a Google account could authenticate a device onto
  your VPN.

## Running it yourself

1. Follow [`SETUP.md`](./SETUP.md) once — creates the GCP project, the
   Workload Identity Federation trust, and all the GitHub secrets/variables
   this repo's workflows expect.
2. Open a PR touching `terraform/` to see the plan-comment flow, then merge
   to `main` to deploy.
3. Point `vpn.conway-hash.com`'s DNS A record at the static IP OpenTofu
   creates (shown in the `deploy` workflow's output).

## Known limitations / possible follow-ups

- Defaults target GCP's **Always Free** tier: `e2-micro` in `us-central1`
  with a 30 GB `pd-standard` disk. That's one free instance per *billing
  account* (not per project), 1 GB RAM (a 2 GB swapfile is provisioned as
  headroom, not a fix), and ~1 GB/month of free egress — a VPN relaying real
  traffic can exceed that. See "Staying inside GCP's Always Free tier" in
  `SETUP.md` before assuming this costs nothing.
- The Headscale API key minted for Headplane expires after 90 days and isn't
  auto-rotated (see "Rotating things" in `SETUP.md`).
- No observability stack (logs/metrics ship nowhere yet beyond what the VM's
  service account permissions allow) — Cloud Logging's Ops Agent would be the
  natural next step.
- No automated backup of `/var/lib/headscale` (the tailnet's state lives only
  on the VM's boot disk).

## License

MIT — see [`LICENSE`](./LICENSE).
