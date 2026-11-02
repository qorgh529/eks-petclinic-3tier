#!/usr/bin/env bash
# Offline checks (no cluster needed). Requires python3 + PyYAML.
#   1. YAML syntax           2. no :latest / untagged images (templated: STABLE/CANARY_IMAGE_TAG)
#   3. no plaintext secrets  4. node-tier placement + non-root securityContext
#   5. stable/canary tags, DB secret per role, JDBC pool cap, KEDA fallback, Prometheus HA, PDBs
#   6. scripts/daily-{stop,start}.sh syntax, offline --dry-run, tests/scripts/daily-stop-start.test.sh (needs jq)
#   7. tracing: placement, IRSA-only Tempo (grafana-community chart, pinned image), was agent injection / service.version / resources
#   8. codebuild: buildspec tag guards + linux/amd64, least-privilege service role policy, .env.example variables,
#      source/backup/Tempo bucket isolation guard, tests/scripts/build-and-push.test.sh
#   9. MySQL 8.4: RDS engine + mysql8.4 parameter group, db job client images, Connector/J (docs/features/rds-mysql-84)
#  10. vpc-provisioning: scripts/nat-{start,stop}.sh syntax + offline --dry-run, tests/scripts/vpc-provisioning.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# .env is created by copying .env.example and is sourced by every script: it must source cleanly.
if ! (set -eu; set -a; . "$ROOT/.env.example") >/dev/null 2>&1; then
  echo "FAIL .env.example does not source cleanly (quote values containing spaces)"
  exit 1
fi

# Daily stop/start: valid bash, and --dry-run runs offline and prints the remaining-cost notice.
for s in daily-stop daily-start; do
  bash -n "$ROOT/scripts/$s.sh" || { echo "FAIL scripts/$s.sh: bash syntax"; exit 1; }
  if ! out=$(AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=petclinic-eks bash "$ROOT/scripts/$s.sh" --dry-run 2>&1) \
     || ! grep -q "Non-stoppable resources" <<<"$out"; then
    echo "FAIL scripts/$s.sh --dry-run"; echo "$out"; exit 1
  fi
done
# NAT start/stop: valid bash, and --dry-run exits before any AWS call.
for s in nat-start nat-stop; do
  bash -n "$ROOT/scripts/$s.sh" || { echo "FAIL scripts/$s.sh: bash syntax"; exit 1; }
  if ! out=$(PATH=/usr/bin:/bin bash "$ROOT/scripts/$s.sh" --dry-run 2>&1) || ! grep -q "DRY-RUN" <<<"$out"; then
    echo "FAIL scripts/$s.sh --dry-run"; echo "$out"; exit 1
  fi
done
for s in infra/aws/provision-aws-resources.sh scripts/deploy-all.sh scripts/build-and-push.sh; do
  bash -n "$ROOT/$s" || { echo "FAIL $s: bash syntax"; exit 1; }
done
# Real-mode branches (lookup errors, RDS stopping, state file, maxSize) against fake aws/kubectl.
bash "$ROOT/tests/scripts/daily-stop-start.test.sh" || { echo "FAIL tests/scripts/daily-stop-start.test.sh"; exit 1; }
# CodeBuild mode of build-and-push.sh (caller tag/target, per-run source key, archive filter, guards) against a fake aws.
bash "$ROOT/tests/scripts/build-and-push.test.sh" || { echo "FAIL tests/scripts/build-and-push.test.sh"; exit 1; }
# deploy-all.sh's /grafana guard (WAF allow-list rule first) against a fake aws.
bash "$ROOT/tests/scripts/grafana-waf-ready.test.sh" || { echo "FAIL tests/scripts/grafana-waf-ready.test.sh"; exit 1; }
# provision-aws-resources.sh vpc (create, re-run, mismatch stops) and NAT start/stop against a stateful fake aws.
bash "$ROOT/tests/scripts/vpc-provisioning.test.sh" || { echo "FAIL tests/scripts/vpc-provisioning.test.sh"; exit 1; }

"${PYTHON:-python3}" - "$ROOT" <<'PY'
import pathlib, re, subprocess, sys
import yaml

root = pathlib.Path(sys.argv[1])
errors = []
def err(msg): errors.append(msg)

tracked = subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True, check=True).stdout.split()
files = [root / f for f in tracked if not f.startswith("app/")]
yamls = [f for f in files if f.suffix in (".yaml", ".yml")]

# 1. YAML syntax
docs = {}
for f in yamls:
    try:
        docs[f] = [d for d in yaml.safe_load_all(f.read_text(encoding="utf-8")) if d]
    except yaml.YAMLError as e:
        err(f"{f.relative_to(root)}: invalid YAML: {e}")

# 2. Images pinned
def check_image(where, image):
    if "${" in image:
        if not image.endswith((":${STABLE_IMAGE_TAG}", ":${CANARY_IMAGE_TAG}")):
            err(f"{where}: templated image must use :${{STABLE_IMAGE_TAG}} or :${{CANARY_IMAGE_TAG}}: {image}")
        return
    name = image.split("@")[0].rsplit("/", 1)[-1]
    if ":" not in name and "@" not in image:
        err(f"{where}: image has no tag: {image}")
    elif name.endswith(":latest"):
        err(f"{where}: image uses :latest: {image}")

for f in files:
    if f.name == "Dockerfile":
        for line in f.read_text(encoding="utf-8").splitlines():
            m = re.match(r"\s*FROM\s+(\S+)", line, re.I)
            if m:
                check_image(f.relative_to(root), m.group(1))
for f, ds in docs.items():
    text = f.read_text(encoding="utf-8")
    for m in re.finditer(r"^\s*(?:-\s*)?image:\s*['\"]?([^\s'\"#]+)", text, re.M):
        check_image(f.relative_to(root), m.group(1))
    for d in ds:
        img = d.get("image") if isinstance(d, dict) else None
        if isinstance(img, dict) and "repository" in img:
            check_image(f.relative_to(root), f"{img['repository']}:{img.get('tag', '')}".rstrip(":"))

# 3. Plaintext secrets
if ".env" in tracked:
    err(".env is tracked by git")
secret_patterns = [
    (r"AKIA[0-9A-Z]{16}", "AWS access key id"),
    (r"(?i)aws_secret_access_key\s*[:=]", "AWS secret key"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key"),
    (r"(?i)\b(password|passwd|secret|token)\b(?::\s+|\s*=\s*)['\"]?(?![\s'\"]*$)(?!\$|\{\{|<|file:|env\.)[^\s'\"]{4,}", "hard-coded credential"),
    (r"\b\d{12}\b", "possible AWS account id"),
]
for f in files:
    if f.suffix in (".jar",) or f.name in (".env.example",) or f.parts[-2:] == ("docs", f.name):
        continue
    try:
        text = f.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for pat, what in secret_patterns:
        for m in re.finditer(pat, text):
            line = text[: m.start()].count("\n") + 1
            err(f"{f.relative_to(root)}:{line}: {what}: {m.group(0)[:40]}")
for f, ds in docs.items():
    for d in ds:
        if isinstance(d, dict) and d.get("kind") == "Secret" and (d.get("data") or d.get("stringData")):
            err(f"{f.relative_to(root)}: Secret with inline data (use ExternalSecret)")
# No Maven profile may carry a DB password.
pom = (root / "app/pom.xml").read_text(encoding="utf-8")
for m in re.finditer(r"<jdbc\.password>[^<]+</jdbc\.password>", pom):
    err(f"app/pom.xml:{pom[:m.start()].count(chr(10)) + 1}: hard-coded jdbc.password")

# 4. Placement + securityContext
TIERS = {"app": None, "critical": "critical", "platform": "platform"}
def pod_spec(d):
    kind = d.get("kind")
    if kind in ("Deployment", "Job", "DaemonSet", "StatefulSet"):
        return d["spec"]["template"]["spec"]
    if kind == "CronJob":
        return d["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return None

def expect_tier(where, spec, tier):
    if (spec.get("nodeSelector") or {}).get("workload-tier") != tier:
        err(f"{where}: nodeSelector workload-tier != {tier}")
    taint = TIERS[tier]
    if taint and not any(t.get("key") == "node-role" and t.get("value") == taint
                         and t.get("effect") == "NoSchedule" for t in spec.get("tolerations") or []):
        err(f"{where}: missing toleration node-role={taint}:NoSchedule")

workloads = 0
for f, ds in docs.items():
    rel = f.relative_to(root)
    if rel.parts[0] != "k8s":
        continue
    for d in ds:
        if not isinstance(d, dict):
            continue
        spec = pod_spec(d)
        if spec is None:
            continue
        workloads += 1
        where = f"{rel}:{d['kind']}/{d['metadata']['name']}"
        expect_tier(where, spec, "critical" if rel.parts[1] == "jobs" else "app")
        psc = spec.get("securityContext") or {}
        if psc.get("runAsNonRoot") is not True or psc.get("runAsUser", 0) == 0:
            err(f"{where}: pod securityContext must set runAsNonRoot: true and a non-zero runAsUser")
        for c in (spec.get("initContainers") or []) + spec["containers"]:
            sc = c.get("securityContext") or {}
            if sc.get("allowPrivilegeEscalation") is not False:
                err(f"{where}/{c['name']}: allowPrivilegeEscalation must be false")
            if "ALL" not in ((sc.get("capabilities") or {}).get("drop") or []):
                err(f"{where}/{c['name']}: capabilities.drop must include ALL")
if workloads == 0:
    err("no workloads found under k8s/")

# Helm values: monitoring on ng-platform, Fluent Bit everywhere.
kps = docs.get(root / "k8s/monitoring/kube-prometheus-values.yaml", [{}])[0]
for name, spec in (("prometheus", kps.get("prometheus", {}).get("prometheusSpec", {})),
                   ("alertmanager", kps.get("alertmanager", {}).get("alertmanagerSpec", {})),
                   ("grafana", kps.get("grafana", {}))):
    expect_tier(f"kube-prometheus-values:{name}", spec, "platform")
fb = docs.get(root / "k8s/logging/fluent-bit-values.yaml", [{}])[0]
if not any(t.get("operator") == "Exists" and "key" not in t for t in fb.get("tolerations") or []):
    err("fluent-bit-values: tolerations must include {operator: Exists}")

# Dockerfiles drop root.
for f in files:
    if f.name == "Dockerfile":
        users = re.findall(r"^\s*USER\s+(\S+)", f.read_text(encoding="utf-8"), re.M)
        if not users or users[-1] in ("0", "root"):
            err(f"{f.relative_to(root)}: final USER must be non-root")

# 5. Operational guards (design Steps 9-11)
k8s_docs = [(f.relative_to(root), d) for f, ds in docs.items() if f.relative_to(root).parts[0] == "k8s"
            for d in ds if isinstance(d, dict)]
def find(kind, name):
    return next((d for _, d in k8s_docs if d.get("kind") == kind and d["metadata"]["name"] == name), None)

# Stable and canary roll out different images.
for rel, d in k8s_docs:
    if d.get("kind") != "Deployment":
        continue
    track = (d["metadata"].get("labels") or {}).get("track")
    want = {"stable": ":${STABLE_IMAGE_TAG}", "canary": ":${CANARY_IMAGE_TAG}"}.get(track)
    for c in pod_spec(d)["containers"]:
        if want and "${" in c["image"] and not c["image"].endswith(want):
            err(f"{rel}:Deployment/{d['metadata']['name']}: track {track} must use {want}")

# Each DB role reads only its own secret; only db-init may use the admin account.
DB_SECRETS = {"petclinic-rds-admin-secret", "petclinic-rds-secret", "petclinic-rds-backup-secret"}
ALLOWED = {"was-stable": {"petclinic-rds-secret"}, "was-canary": {"petclinic-rds-secret"},
           "db-backup": {"petclinic-rds-backup-secret"}, "db-init": DB_SECRETS}
for rel, d in k8s_docs:
    spec = pod_spec(d)
    if spec is None:
        continue
    name = d["metadata"]["name"]
    for c in (spec.get("initContainers") or []) + spec["containers"]:
        for e in c.get("env") or []:
            ref = ((e.get("valueFrom") or {}).get("secretKeyRef") or {}).get("name")
            if ref in DB_SECRETS and ref not in ALLOWED.get(name, set()):
                err(f"{rel}:{d['kind']}/{name}: must not read {ref}")
            if name == "db-init" and e["name"] in ("JDBC_USERNAME", "MYSQL_PWD") and ref != "petclinic-rds-admin-secret":
                err(f"{rel}:Job/db-init: {e['name']} must come from petclinic-rds-admin-secret")
for es in ("petclinic-rds-admin", "petclinic-rds", "petclinic-rds-backup"):
    if find("ExternalSecret", es) is None:
        err(f"k8s/secrets: missing ExternalSecret/{es}")

# JDBC pool is capped (RDS connection budget).
props = (root / "app/src/main/resources/spring/data-access.properties").read_text(encoding="utf-8")
m = re.search(r"^jdbc\.pool\.maxActive=(\d+)\s*$", props, re.M)
if not m or int(m.group(1)) > 10:
    err("data-access.properties: jdbc.pool.maxActive must be set and <= 10")
if 'p:maxActive="${jdbc.pool.maxActive}"' not in (root / "app/src/main/resources/spring/datasource-config.xml").read_text(encoding="utf-8"):
    err("datasource-config.xml: dataSource must use ${jdbc.pool.maxActive}")

# KEDA keeps a safe replica count when Prometheus is down.
for name in ("was-stable", "was-canary"):
    so = find("ScaledObject", name)
    if not so or not (so["spec"].get("fallback") or {}).get("replicas"):
        err(f"ScaledObject/{name}: fallback.replicas must be set")

# Prometheus survives one AZ.
if int(kps.get("prometheus", {}).get("prometheusSpec", {}).get("replicas", 1)) < 2:
    err("kube-prometheus-values: prometheus.prometheusSpec.replicas must be >= 2")

# Stable tracks keep a pod through voluntary disruptions.
for app in ("web", "was"):
    sel = {"app": app, "track": "stable"}
    if not any(d.get("kind") == "PodDisruptionBudget" and (d["spec"].get("selector") or {}).get("matchLabels") == sel
               for _, d in k8s_docs):
        err(f"missing PodDisruptionBudget for {sel}")

# EBS CSI add-on version is pinned (design §4.1).
eks = docs.get(root / "infra/eksctl/cluster.yaml", [{}])[0]
for a in eks.get("addons") or []:
    if a["name"] == "aws-ebs-csi-driver" and not a.get("version"):
        err("infra/eksctl/cluster.yaml: addon aws-ebs-csi-driver must set version")

# Webhook URLs carry tokens: read from the ESO-synced Secret file, never inlined in Helm values.
for r in kps.get("alertmanager", {}).get("config", {}).get("receivers") or []:
    for w in r.get("webhook_configs") or []:
        if "url" in w or not w.get("url_file"):
            err(f"kube-prometheus-values: receiver {r.get('name')} must use url_file, not url")

# 7. Tracing (docs/features/apm-tracing/design.md)
def values(path):
    return docs.get(root / path, [{}])[0]
expect_tier("otel-operator-values", values("k8s/tracing/otel-operator-values.yaml"), "critical")
expect_tier("otel-collector-values", values("k8s/tracing/otel-collector-values.yaml"), "platform")
tempo = values("k8s/tracing/tempo-values.yaml")
expect_tier("tempo-values", tempo, "platform")
s3 = (((tempo.get("tempo") or {}).get("storage") or {}).get("trace") or {}).get("s3") or {}
if any(k in s3 for k in ("access_key", "secret_key")):
    err("tempo-values: S3 must use IRSA, not access_key/secret_key")
if (tempo.get("serviceAccount") or {}).get("name") != "tempo" or not any(
        (sa.get("metadata") or {}) == {"name": "tempo", "namespace": "monitoring"}
        for sa in (eks.get("iam") or {}).get("serviceAccounts") or []):
    err("tempo-values: serviceAccount tempo must be the IRSA SA monitoring/tempo in infra/eksctl/cluster.yaml")
# Tracing pods run non-root without privilege escalation; collector and Tempo also on a read-only root.
collector = values("k8s/tracing/otel-collector-values.yaml")
operator = values("k8s/tracing/otel-operator-values.yaml")
for where, pod, containers, ro in (
        ("otel-operator-values", operator.get("securityContext"),
         [(operator.get("manager") or {}).get("securityContext"), (operator.get("kubeRBACProxy") or {}).get("securityContext")], False),
        ("otel-collector-values", collector.get("podSecurityContext"), [collector.get("securityContext")], True),
        ("tempo-values", tempo.get("securityContext"), [(tempo.get("tempo") or {}).get("securityContext")], True)):
    if (pod or {}).get("runAsNonRoot") is not True:
        err(f"{where}: pod securityContext must set runAsNonRoot: true")
    for sc in containers:
        sc = sc or {}
        if sc.get("allowPrivilegeEscalation") is not False or "ALL" not in ((sc.get("capabilities") or {}).get("drop") or []):
            err(f"{where}: container securityContext must set allowPrivilegeEscalation: false and drop ALL")
        if ro and sc.get("readOnlyRootFilesystem") is not True:
            err(f"{where}: container securityContext must set readOnlyRootFilesystem: true")
# Block retention follows TEMPO_RETENTION_DAYS like the S3 lifecycle.
if (tempo.get("tempo") or {}).get("retention") != "${TEMPO_RETENTION_HOURS}":
    err("tempo-values: tempo.retention must be ${TEMPO_RETENTION_HOURS} (rendered from TEMPO_RETENTION_DAYS)")
# Tempo image sits under tempo.repository/tag, outside the image: keys checked in section 2.
tempo_image = tempo.get("tempo") or {}
check_image("k8s/tracing/tempo-values.yaml", f"{tempo_image.get('repository', '')}:{tempo_image.get('tag', '')}".rstrip(":"))
# Tempo 3 has no -mem-ballast-size-mbs flag (docs/features/tempo-chart-migration/design.md).
if "memBallastSizeMbs" in tempo_image:
    err("tempo-values: tempo.memBallastSizeMbs was removed in Tempo 3; drop it")
# grafana/tempo is deprecated upstream; the single-binary chart lives in grafana-community.
deploy = (root / "scripts/deploy-all.sh").read_text(encoding="utf-8")
if "grafana.github.io/helm-charts" in deploy or re.search(r"\bgrafana/tempo\b", deploy):
    err("scripts/deploy-all.sh: use grafana-community/tempo, not the deprecated grafana/tempo chart")
if not re.search(r"helm upgrade --install tempo grafana-community/tempo \\\n\s+--version \d+\.\d+\.\d+", deploy):
    err("scripts/deploy-all.sh: tempo must be installed from grafana-community/tempo with a pinned --version")
inst = find("Instrumentation", "petclinic-java")
if not inst or (inst["spec"].get("sampler") or {}).get("argument") != "${OTEL_TRACES_SAMPLER_ARG}":
    err("Instrumentation/petclinic-java: sampler.argument must be ${OTEL_TRACES_SAMPLER_ARG}")
def mib(q):
    q = str(q)
    return int(q[:-2]) * (1024 if q.endswith("Gi") else 1) if q[-2:] in ("Mi", "Gi") else 0
for track in ("stable", "canary"):
    d = find("Deployment", f"was-{track}")
    tmpl = d["spec"]["template"]
    if (tmpl["metadata"].get("annotations") or {}).get("instrumentation.opentelemetry.io/inject-java") != "petclinic-java":
        err(f"Deployment/was-{track}: missing inject-java: petclinic-java annotation")
    c = tmpl["spec"]["containers"][0]
    env = {e["name"]: e.get("value") for e in c.get("env") or []}
    if f"service.version={track}" not in (env.get("OTEL_RESOURCE_ATTRIBUTES") or "").split(","):
        err(f"Deployment/was-{track}: OTEL_RESOURCE_ATTRIBUTES must carry service.version={track}")
    res = c.get("resources") or {}
    if mib((res.get("requests") or {}).get("memory")) < 1280 or mib((res.get("limits") or {}).get("memory")) < 2048:
        err(f"Deployment/was-{track}: memory must be >= 1280Mi request / 2Gi limit (Java agent overhead)")
    if not (c.get("readinessProbe") or {}).get("initialDelaySeconds"):
        err(f"Deployment/was-{track}: readinessProbe.initialDelaySeconds must be set")

# 8. CodeBuild image build (docs/features/codebuild-image-build/design.md)
import json
bs = docs.get(root / "buildspec.yml", [None])[0]
if not isinstance(bs, dict) or str(bs.get("version")) != "0.2":
    err("buildspec.yml: missing or not version 0.2")
else:
    phases = bs.get("phases") or {}
    cmds = lambda ph: "\n".join(str(c) for c in (phases.get(ph) or {}).get("commands") or [])
    if '"$IMAGE_TAG" != "latest"' not in cmds("pre_build"):
        err("buildspec.yml: pre_build must reject IMAGE_TAG=latest")
    builds = re.findall(r"docker build\b[^\n]*", cmds("build"))
    if len(builds) != 2 or any("--platform linux/amd64" not in b for b in builds):
        err("buildspec.yml: build must run two docker builds (was, web) with --platform linux/amd64")
    if (phases.get("build") or {}).get("on-failure") != "ABORT":
        err("buildspec.yml: build phase must set on-failure: ABORT (no push after a failed build)")
    if (phases.get("post_build") or {}).get("on-failure") != "ABORT":
        err("buildspec.yml: post_build must set on-failure: ABORT (no web push after a failed was push)")
    if "=~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$" not in cmds("pre_build"):
        err("buildspec.yml: pre_build must check IMAGE_TAG against the docker tag grammar")
try:
    pol = json.loads((root / "infra/aws/iam-policies/codebuild-policy.json").read_text(encoding="utf-8"))
    for st in pol["Statement"]:
        acts = st["Action"] if isinstance(st["Action"], list) else [st["Action"]]
        res = st["Resource"] if isinstance(st["Resource"], list) else [st["Resource"]]
        if "*" in res and acts != ["ecr:GetAuthorizationToken"]:
            err(f"codebuild-policy.json: {st.get('Sid')}: only ecr:GetAuthorizationToken may use Resource *")
        if any(a.endswith("*") for a in acts):
            err(f"codebuild-policy.json: {st.get('Sid')}: wildcard action")
        for a in acts:
            if a.startswith("s3:") and a not in ("s3:GetObject", "s3:GetObjectVersion", "s3:GetBucketLocation"):
                err(f"codebuild-policy.json: {a}: CodeBuild only reads the source bucket")
        for r in res:
            if r.startswith("arn:aws:s3:::") and "${CODEBUILD_S3_BUCKET_NAME}" not in r:
                err(f"codebuild-policy.json: S3 access outside the CodeBuild bucket: {r}")
            if r.startswith("arn:aws:ecr:") and not r.endswith(("repository/petclinic-web", "repository/petclinic-was")):
                err(f"codebuild-policy.json: ECR access outside petclinic-web/was: {r}")
except (OSError, ValueError, KeyError) as e:
    err(f"infra/aws/iam-policies/codebuild-policy.json: {e}")
# The CodeBuild bucket gets a 1-day expiry: provisioning must refuse a name shared with backup/Tempo.
prov = (root / "infra/aws/provision-aws-resources.sh").read_text(encoding="utf-8")
if not re.search(r'"\$CODEBUILD_S3_BUCKET_NAME" != "\$BACKUP_S3_BUCKET_NAME" \] && \[ "\$CODEBUILD_S3_BUCKET_NAME" != "\$TEMPO_S3_BUCKET_NAME"', prov):
    err("provision-aws-resources.sh: pre-cluster must refuse CODEBUILD_S3_BUCKET_NAME equal to the backup or Tempo bucket")
env_example = (root / ".env.example").read_text(encoding="utf-8")
for v in ("CODEBUILD_PROJECT_NAME", "CODEBUILD_S3_BUCKET_NAME"):
    if not re.search(rf"^{v}=", env_example, re.M):
        err(f".env.example: missing {v}")

# 9. MySQL 8.4 LTS everywhere (docs/features/rds-mysql-84/design.md): 8.0 is past standard support.
MYSQL = "8.4.11"
if f"--engine-version {MYSQL}" not in prov or "--db-parameter-group-family mysql8.4" not in prov:
    err(f"provision-aws-resources.sh: RDS must use --engine-version {MYSQL} and parameter group family mysql8.4")
if "require_secure_transport,ParameterValue=ON" not in prov:
    err("provision-aws-resources.sh: RDS parameter group must keep require_secure_transport=ON")
for job in ("k8s/jobs/job-db-init.yaml", "k8s/jobs/cronjob-db-backup.yaml"):
    imgs = re.findall(r"image:\s*(mysql:\S+)", (root / job).read_text(encoding="utf-8"))
    if not imgs or any(i != f"mysql:{MYSQL}" for i in imgs):
        err(f"{job}: mysql client image must be mysql:{MYSQL} (got {imgs})")
if "<mysql-driver.version>8.4.0</mysql-driver.version>" not in pom:
    err("app/pom.xml: mysql-driver.version must be Connector/J 8.4.0")

# 10. Zone spread survives rollouts (docs/features/spread-on-rollout/design.md): without
# matchLabelKeys the old ReplicaSet's pods are counted and new pods can all land in one zone.
SPREAD = {("k8s/web/deployment.yaml", "web"): "DoNotSchedule",
          ("k8s/web/deployment.yaml", "web-canary"): "ScheduleAnyway",
          ("k8s/was/deployment-stable.yaml", "was-stable"): "DoNotSchedule",
          ("k8s/was/deployment-canary.yaml", "was-canary"): "ScheduleAnyway"}
for (f, name), policy in SPREAD.items():
    dep = next((d for d in docs.get(root / f, []) if d and d.get("kind") == "Deployment"
                and d["metadata"]["name"] == name), None)
    if dep is None:
        err(f"{f}: Deployment {name} not found")
        continue
    zone = [c for c in dep["spec"]["template"]["spec"].get("topologySpreadConstraints") or []
            if c.get("topologyKey") == "topology.kubernetes.io/zone"]
    if len(zone) != 1:
        err(f"{f} {name}: needs exactly one zone topologySpreadConstraint")
        continue
    c = zone[0]
    if c.get("maxSkew") != 1 or c.get("whenUnsatisfiable") != policy:
        err(f"{f} {name}: zone spread must be maxSkew 1, whenUnsatisfiable {policy}")
    keys = c.get("matchLabelKeys")
    if not isinstance(keys, list) or "pod-template-hash" not in keys:  # a bare string would match by substring
        err(f"{f} {name}: zone spread must set matchLabelKeys: [pod-template-hash]")

# 11. Graceful shutdown (docs/features/graceful-shutdown/design.md): each container waits in preStop
# until NGF and kube-proxy drop the pod, and the grace period covers that wait plus the drain.
SHUTDOWN = {("k8s/web/deployment.yaml", "web"): 35, ("k8s/web/deployment.yaml", "web-canary"): 35,
            ("k8s/was/deployment-stable.yaml", "was-stable"): 45,
            ("k8s/was/deployment-canary.yaml", "was-canary"): 45}
PRESTOP = 15
for (f, name), grace in SHUTDOWN.items():
    dep = next((d for d in docs.get(root / f, []) if d and d.get("kind") == "Deployment"
                and d["metadata"]["name"] == name), None)
    if dep is None:
        err(f"{f}: Deployment {name} not found")
        continue
    spec = dep["spec"]["template"]["spec"]
    tgps = spec.get("terminationGracePeriodSeconds")
    if not isinstance(tgps, int) or tgps < grace:
        err(f"{f} {name}: terminationGracePeriodSeconds must be an integer >= {grace}")
    for c in spec["containers"]:
        secs = ((((c.get("lifecycle") or {}).get("preStop") or {}).get("sleep") or {}).get("seconds"))
        if not isinstance(secs, int) or secs < PRESTOP:
            err(f"{f} {name}/{c['name']}: lifecycle.preStop.sleep.seconds must be an integer >= {PRESTOP}")
        elif isinstance(tgps, int) and tgps <= secs:
            err(f"{f} {name}/{c['name']}: terminationGracePeriodSeconds must exceed the preStop sleep")

# 12. Grafana at /grafana (docs/features/grafana-public-path/design.md): sub-path serving, closed
# sign-up/anonymous access, a route that only reaches the Grafana Service, and a WAF allow-list.
def one(f, kind):
    return next((d for d in docs.get(root / f, []) if d and d.get("kind") == kind), None)
values = next(iter(docs.get(root / "k8s/monitoring/kube-prometheus-values.yaml", [])), {})
gini = (values.get("grafana") or {}).get("grafana.ini") or {}
want = {("server", "root_url"): "https://${DOMAIN_NAME}/grafana/", ("server", "serve_from_sub_path"): True,
        ("security", "cookie_secure"): True, ("security", "cookie_samesite"): "lax",
        ("security", "allow_embedding"): False,
        ("users", "allow_sign_up"): False, ("auth.anonymous", "enabled"): False}
if ((values.get("grafana") or {}).get("serviceMonitor") or {}).get("path") != "/grafana/metrics":
    err("kube-prometheus-values.yaml: grafana.serviceMonitor.path must be /grafana/metrics (sub-path serving)")
for (sec, key), val in want.items():
    if (gini.get(sec) or {}).get(key) != val:
        err(f"kube-prometheus-values.yaml: grafana.ini {sec}.{key} must be {val!r}")
route = one("k8s/gateway/httproute-grafana.yaml", "HTTPRoute")
rules = (route or {}).get("spec", {}).get("rules") or []
if (len(rules) != 1 or [m.get("path") for m in rules[0].get("matches", [])] != [{"type": "PathPrefix", "value": "/grafana"}]
        or [(b.get("namespace"), b.get("name")) for b in rules[0].get("backendRefs", [])]
        != [("monitoring", "kube-prometheus-stack-grafana")]):
    err("httproute-grafana.yaml: one rule, PathPrefix /grafana -> monitoring/kube-prometheus-stack-grafana")
grant = one("k8s/monitoring/referencegrant-grafana.yaml", "ReferenceGrant")
if [t.get("name") for t in (grant or {}).get("spec", {}).get("to", [])] != ["kube-prometheus-stack-grafana"]:
    err("referencegrant-grafana.yaml: must grant only Service kube-prometheus-stack-grafana")
# Exactly two sources (the gateway data plane, Prometheus), each limited to TCP 3000: an empty rule,
# a missing source or a missing port list would open Grafana wider.
gnp = (one("k8s/monitoring/networkpolicy-grafana.yaml", "NetworkPolicy") or {}).get("spec", {})
srcs = sorted(tuple(sorted(f.items())) for r in gnp.get("ingress", []) for f in r.get("from", []))
if (gnp.get("podSelector") != {"matchLabels": {"app.kubernetes.io/name": "grafana"}}
        or gnp.get("policyTypes") != ["Ingress"] or len(gnp.get("ingress", [])) != 2
        or any(r.get("ports") != [{"protocol": "TCP", "port": 3000}] or len(r.get("from", [])) != 1
               for r in gnp.get("ingress", []))
        or srcs != sorted([
            (("namespaceSelector", {"matchLabels": {"kubernetes.io/metadata.name": "nginx-gateway"}}),
             ("podSelector", {"matchLabels": {"gateway.networking.k8s.io/gateway-name": "petclinic-gateway"}})),
            (("podSelector", {"matchLabels": {"app.kubernetes.io/name": "prometheus"}}),)])):
    err("networkpolicy-grafana.yaml: Grafana ingress only from the gateway data plane and Prometheus, TCP 3000")
listener = (one("k8s/gateway/gateway.yaml", "Gateway") or {}).get("spec", {}).get("listeners", [{}])[0]
allowed = [v for e in listener.get("allowedRoutes", {}).get("namespaces", {}).get("selector", {})
           .get("matchExpressions", []) for v in e.get("values", [])]
if sorted(allowed) != ["nginx-gateway", "petclinic"]:
    err("gateway.yaml: routes allowed only from petclinic and nginx-gateway")
if not re.search(r"^GRAFANA_ALLOWED_CIDRS=$", (root / ".env.example").read_text(encoding="utf-8"), re.M):
    err(".env.example: GRAFANA_ALLOWED_CIDRS= must be present and empty")
if ("grafana-waf) grafana_waf" not in prov or '"URL_DECODE"' not in prov or '"NORMALIZE_PATH"' not in prov
        or "update-web-acl --scope REGIONAL --name \"$acl_name\" --id \"$acl_id\" --cli-binary-format raw-in-base64-out" not in prov):
    err("provision-aws-resources.sh: grafana-waf must block /grafana after URL_DECODE + NORMALIZE_PATH,"
        " sending SearchString raw (--cli-binary-format raw-in-base64-out)")

# 13. Landing page and the staff app under /was (docs/features/landing-page/design.md).
for f in ("k8s/was/deployment-stable.yaml", "k8s/was/deployment-canary.yaml"):
    dep = one(f, "Deployment") or {}
    for c in dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])[:1]:
        for probe in ("startupProbe", "readinessProbe"):
            # Phase 1 (Q7): / so either image fits the shared manifests; /was/ in phase 2.
            if ((c.get(probe) or {}).get("httpGet") or {}).get("path") != "/":
                err(f"{f}: {c.get('name')} {probe} must GET / until phase 2 (old and new images both answer it)")
was_df = (root / "docker/was/Dockerfile").read_text(encoding="utf-8")
if ("webapps/was" not in was_df or "webapps/ROOT" in was_df or "COPY docker/was/server.xml conf/server.xml" not in was_df
        or "COPY docker/was/rewrite.config /opt/petclinic/rewrite.config" not in was_df
        or "conf/Catalina/localhost/rewrite.config" not in (root / "docker/was/setenv.sh").read_text(encoding="utf-8")):
    err("docker/was/Dockerfile: deploy the app as webapps/was (not ROOT) with server.xml; setenv.sh puts the phase 1"
        " rewrite.config under conf/Catalina (an emptyDir in k8s)")
sx = (root / "docker/was/server.xml").read_text(encoding="utf-8")
if ("org.apache.catalina.valves.RemoteIpValve" not in sx or 'protocolHeader="x-forwarded-proto"' not in sx
        or 'internalProxies="10\\.' not in sx or "org.apache.catalina.valves.rewrite.RewriteValve" not in sx):
    err("docker/was/server.xml: RemoteIpValve trusting x-forwarded-proto from private addresses only, and the phase 1 RewriteValve")
ngx = (root / "docker/web/nginx.conf").read_text(encoding="utf-8")
was_loc = re.search(r"location /was/ \{(.*?)\n    \}", ngx, re.S)  # ${VAR} braces inside
if (not was_loc or "proxy_set_header X-Forwarded-Proto https;" not in was_loc.group(1)
        or "location = / {" not in ngx or "error_page 404 /404.html;" not in ngx or "absolute_redirect off;" not in ngx
        or re.search(r"location / \{[^}]*proxy_pass", ngx, re.S)):
    err("docker/web/nginx.conf: / is static (index.html, 404 page), only /was/ is proxied with X-Forwarded-Proto https,"
        " and Nginx's own redirects are relative (absolute_redirect off)")
for page in ("docker/web/static/index.html", "docker/web/static/404.html"):
    if not (root / page).is_file():
        err(f"{page}: missing")
body = root / "infra/aws/waf-staff-403.html"
if not body.is_file() or body.stat().st_size > 4096:
    err("infra/aws/waf-staff-403.html: WAF custom response body must exist and stay within 4 KB")
elif ('src="/resources/images/403.webp"' not in body.read_text(encoding="utf-8")
        or not (root / "app/src/main/webapp/resources/images/403.webp").is_file()):
    err("waf-staff-403.html: its image must be the public /resources/images/403.webp served by web Nginx")
# Q7: the WAS rolls out before web: a new WAS fits an old web, a new web does not fit an old WAS.
dep = (root / "scripts/deploy-all.sh").read_text(encoding="utf-8")
order = [dep.find(x) for x in ('render_all "$K/was"', "rollout status deploy/was-stable", 'render_all "$K/web"')]
if -1 in order or order != sorted(order):
    err("deploy-all.sh: apply the WAS and wait for its rollout before applying the web manifests")
if 'PROMOTE_STABLE:-}" != 1' not in dep or dep.find("PROMOTE_STABLE") > dep.find('render_all "$K/was"'):
    err("deploy-all.sh: a changed STABLE_IMAGE_TAG must need PROMOTE_STABLE=1, checked before any workload changes")
rw = (root / "docker/was/rewrite.config").read_text(encoding="utf-8")
if "RewriteCond %{REQUEST_URI} !^/was(/.*)?$" not in rw or "RewriteRule ^/(.*)$ /was/$1" not in rw:
    err("docker/was/rewrite.config: phase 1 must send everything outside /was to the /was app")
if ("rule=BlockUnauthorizedStaffAccess" not in prov or 'path("/was")' not in prov
        or "--custom-response-bodies" not in prov):
    err("provision-aws-resources.sh: grafana-waf must block /grafana and /was in one rule with the 403 page")

if errors:
    print("\n".join("FAIL " + e for e in errors))
    sys.exit(1)
print(f"OK: {len(yamls)} YAML files, {workloads} workloads checked")
PY
