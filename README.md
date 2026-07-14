# Pacific Shift CI

Shared GitHub Actions building blocks for Pacific Shift Labs repositories.

## Reusable quality gate

`.github/workflows/quality-gate.yml` runs pinned versions of ruff, mypy,
pytest/pytest-cov, Bandit, Gitleaks, and Trivy. During initial rollout the first
five tools report their findings in distinct job-summary sections without
blocking. Remote BuildKit exports the caller image as a runner-local OCI tar;
Trivy scans that built image without pushing it and blocks on HIGH or CRITICAL
vulnerabilities.

Callers should place the quality job before build/deploy with `needs`:

```yaml
jobs:
  quality:
    uses: m3rrym4n/pacific-shift-ci/.github/workflows/quality-gate.yml@main
    with:
      runner_labels: '["self-hosted", "zimaos", "my-app"]'
      coverage_threshold: 60
      source_paths: app tests
      bandit_paths: app

  deploy:
    needs: quality
    uses: m3rrym4n/pacific-shift-ci/.github/workflows/build-deploy-verify.yml@main
    # Existing build/deploy inputs and secrets follow.
```

The caller owns event triggers. Configure `push` and `pull_request` for `dev`;
the reusable workflow itself intentionally uses only `workflow_call`.

## Reusable development deployment

`.github/workflows/build-deploy-verify.yml` builds a caller repository with the
shared BuildKit daemon, pushes immutable and rolling tags to Zot, replaces an
existing container through Dockhand, verifies it, and restores the exact
previous container configuration if deployment or verification fails.

The target container must already exist. Its inspected configuration is the
deployment template: command, entrypoint, environment, labels, bind mounts,
ports, restart policy, network mode, privilege, user, working directory, and
read-only-root setting are preserved. Only the image is changed.

Example caller:

```yaml
name: Dev Build and Deploy

on:
  push:
    branches: [dev]
  workflow_dispatch:
    inputs:
      simulate_failure:
        description: Force failure after replacement to test rollback
        type: boolean
        default: false

jobs:
  deploy:
    uses: m3rrym4n/pacific-shift-ci/.github/workflows/build-deploy-verify.yml@main
    with:
      runner_labels: '["self-hosted", "zimaos", "my-app"]'
      image_repository: my-app/my-app
      container_name: my-app-dev
      app_url: http://192.168.1.68:8001
      health_path: /health
      prepare_command: |
        git rev-parse --short "$GITHUB_SHA" > app/build_info.txt
        date -u +"%Y-%m-%dT%H:%M:%SZ" >> app/build_info.txt
      simulate_failure: ${{ inputs.simulate_failure || false }}
    secrets: inherit
```

Required repository/environment secrets are `DOCKHAND_URL` and
`DOCKHAND_TOKEN`. The defaults assume Zot at `192.168.1.68:5050`, the remote
BuildKit socket at `unix:///run/buildkit/buildkitd.sock`, and a `dev` tag
prefix; each is overridable.

### Stronger application verification

The default verification requires the target container to be running the exact
new image and requires an HTTP 2xx response from `app_url + health_path`.
Applications can add a stronger check with `strong_verify_command`. It runs
only after the generic checks pass and receives `APP_URL`, `HEALTH_URL`,
`EXPECTED_IMAGE`, and `CONTAINER_NAME` in its environment. For example:

```yaml
strong_verify_command: |
  body=$(curl --fail --silent --show-error "$APP_URL/")
  count=$(printf '%s\n' "$body" | sed -n 's/.*data-track-count="\([0-9][0-9]*\)".*/\1/p')
  test -n "$count" && test "$count" -gt 0
```

Use `workflow_dispatch` with `simulate_failure: true` to exercise rollback
without relying on application or network flakiness.
