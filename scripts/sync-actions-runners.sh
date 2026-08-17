#!/usr/bin/env bash
set -euo pipefail

# Adds a runner scale set for every private, non-archived, non-fork repo
# under $owner that has a .github/workflows directory and isn't covered
# yet. Installs the shared GitHub App on each new repo. Never removes an
# existing scale set: a repo losing its CI or being archived is left for a
# human to decide, not auto-pruned. See ADR 0015 and
# docs/runbooks/actions-runner-controller.md.
#
# Requires ARC_SYNC_PAT in the environment: a classic PAT with the `repo`
# scope, used only for the two calls that need account-wide read/install
# access (listing repos, adding a repo to the App installation). Git
# operations use whatever GH_TOKEN/credentials the caller already has.

owner="fobiat"
installation_id="154391118"
arc_dir="kubernetes/apps/actions-runner-system"
excluded=("home-ops" "AppleJackRP-s-box")

is_excluded() {
  local name="$1"
  for e in "${excluded[@]}"; do
    [[ "$name" == "$e" ]] && return 0
  done
  return 1
}

is_covered() {
  local name="$1"
  grep -qh "githubConfigUrl: https://github.com/$owner/$name$" "$arc_dir"/*/app/helmrelease.yaml 2>/dev/null
}

has_ci() {
  GH_TOKEN="$ARC_SYNC_PAT" gh api "repos/$owner/$1/contents/.github/workflows" >/dev/null 2>&1
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-|-$//g'
}

scaffold() {
  local name="$1" slug="$2"
  local dir="$arc_dir/$slug"

  mkdir -p "$dir/app"

  cat >"$dir/ks.yaml" <<EOF
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: actions-runner-$slug
  namespace: flux-system
spec:
  dependsOn:
    - name: actions-runner-controller
  targetNamespace: actions-runner-system
  commonMetadata:
    labels:
      app.kubernetes.io/name: actions-runner-$slug
  path: ./$dir/app
  prune: true
  wait: true
  interval: 1h
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
EOF

  cat >"$dir/app/kustomization.yaml" <<EOF
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: actions-runner-system
resources:
  - ./helmrelease.yaml
EOF

  cat >"$dir/app/helmrelease.yaml" <<EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: $slug-runners
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  url: oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
  ref:
    tag: 0.14.2
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: $slug-runners
spec:
  interval: 1h
  chartRef:
    kind: OCIRepository
    name: $slug-runners
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
      strategy: rollback
  values:
    githubConfigUrl: https://github.com/$owner/$name
    githubConfigSecret: actions-runner-github-app
    controllerServiceAccount:
      namespace: actions-runner-system
      name: actions-runner-controller-gha-rs-controller
    # PLAN.md's phase three section: start low on a single four-core node.
    # The namespace's shared ResourceQuota, not this number, is the real
    # cross-repo ceiling once more than one scale set can be busy at once.
    minRunners: 0
    maxRunners: 2
    # kubernetes mode: see ADR 0015 for why (no Docker daemon on Talos, no
    # loadable workload kernel modules).
    containerMode:
      type: kubernetes
      kubernetesModeWorkVolumeClaim:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 2Gi
    template:
      spec:
        containers:
          - name: runner
            image: ghcr.io/actions/actions-runner:latest
            command: ["/home/runner/run.sh"]
            # Single node, four cores. See AGENTS.md rule 7. The
            # ResourceQuota and LimitRange in ../controller/app bound the
            # per-step job pods this mode spawns; this bounds the runner's
            # own control pod.
            resources:
              requests:
                cpu: 100m
                memory: 256Mi
              limits:
                cpu: 500m
                memory: 1Gi
EOF

  awk -v line="  - ./$slug/ks.yaml" \
    '/  - \.\/netpol\/ks\.yaml/ && !ins {print line; ins=1} {print}' \
    "$arc_dir/kustomization.yaml" >"$arc_dir/kustomization.yaml.tmp"
  mv "$arc_dir/kustomization.yaml.tmp" "$arc_dir/kustomization.yaml"
}

install_app() {
  local name="$1"
  local repo_id
  repo_id="$(GH_TOKEN="$ARC_SYNC_PAT" gh api "repos/$owner/$name" --jq .id)"
  GH_TOKEN="$ARC_SYNC_PAT" gh api --method PUT \
    "user/installations/$installation_id/repositories/$repo_id" >/dev/null
}

added=()

while IFS= read -r name; do
  is_excluded "$name" && continue
  is_covered "$name" && continue
  has_ci "$name" || continue

  slug="$(slugify "$name")"
  echo "adding scale set for $name (slug: $slug)" >&2
  scaffold "$name" "$slug"
  install_app "$name"
  added+=("$name")
done < <(GH_TOKEN="$ARC_SYNC_PAT" gh repo list "$owner" --visibility private --limit 200 \
  --json name,isArchived,isFork \
  --jq '.[] | select(.isArchived==false and .isFork==false) | .name')

if [[ ${#added[@]} -eq 0 ]]; then
  echo "no new repos to add" >&2
  exit 0
fi

printf '%s\n' "${added[@]}" >added-repos.txt
