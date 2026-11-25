# Deploy Argus to Gemini Enterprise — step by step

> Architecture, sub-agents, the deep-diligence pipeline, local development and
> evaluation are in [README.md](README.md). This page is only about getting the
> agent **into your Gemini Enterprise (GE) app**.

**What you get:** a Reasoning Engine on Agent Runtime (with Agent Identity), logs +
artifacts buckets (whitepaper PDFs, charts, infographics), least-privilege IAM, the
DeepMind **Science Skills** published to Agent Registry, and a GE registration named
**"Argus — Life Sciences M&A Diligence"**.

**Time:** ~20 min (skills sync ≈5 min + one Cloud Build run).

---

## Step 0 — Prerequisites (once per workstation)

```bash
gcloud --version                     # ≥ 500
gcloud components install alpha      # Agent Registry commands
uv --version                         # https://docs.astral.sh/uv/
git --version
gcloud auth login                    # a project Owner / Editor+IAM Admin on the target project
```

A **Gemini Enterprise app** must exist in the project
(Console → *Gemini Enterprise* → *Apps*).

## Step 1 — Configure

From the repository root:

```bash
cp .env.example .env        # skip if you already did this for another agent
```

| Key | Value for this agent |
| --- | --- |
| `PROJECT_ID` | your project, e.g. `eg-telix` |
| `REGION` | same geography as the GE app (`eu` → `europe-west4`; `us`/`global` → `us-central1`) |
| `GE_APP_ID` | leave empty — detected in Step 2 |
| **`EDGAR_USER_AGENT`** | **required** — SEC EDGAR policy: `"<Company name> <contact email>"`, no commas |
| `ARGUS_EXTRA_ENV` | *(optional)* e.g. `ARGUS_SHOW_THOUGHTS=0;ARGUS_MODEL=gemini-3.7-flash` |

Defaults: `ARGUS_MODEL=gemini-3.7-flash`, `ARGUS_IMAGE_MODEL=gemini-3-pro-image`,
`AGENT_REGISTRY_LOCATION=global` (see [`.env.example`](.env.example)).

## Step 2 — Bootstrap the project (once per project, idempotent)

```bash
scripts/bootstrap.sh
```

## Step 3 — Publish the Science Skills to Agent Registry

Argus queries openFDA, ClinicalTrials.gov, ChEMBL, Open Targets, UniProt, PubMed and
Europe PMC through [Google DeepMind Science Skills](https://github.com/google-deepmind/science-skills)
loaded from **Agent Registry** at runtime.

```bash
scripts/sync_science_skills.sh             # clone → zip → create/activate skills (idempotent)
scripts/sync_science_skills.sh --dry-run   # see what would change
```

`scripts/deploy.sh argus` runs this automatically; set `SKIP_SKILLS_SYNC=1` to skip it.

## Step 4 — Deploy and register

```bash
scripts/deploy.sh argus
```

Cloud Build (as the deployer SA): Terraform (Reasoning Engine, logs + artifacts buckets,
IAM incl. `roles/agentregistry.viewer` for the agent identity) → `agents-cli deploy` →
`agents-cli publish gemini-enterprise`. Add `--async` to return immediately,
`--no-register` to skip the GE step.

## Step 5 — Verify

```bash
scripts/verify.sh argus
scripts/verify.sh argus --smoke
```

Expected:

```
✔ Reasoning Engine: projects/…/reasoningEngines/… (updated …)
✔ GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false
✔ registered in GE as 'Argus — Life Sciences M&A Diligence'  [ENABLED]
✔ GE path works: "AGENT OK"        # with --smoke
```

`verify.sh` checks four things: the Reasoning Engine exists, the required runtime env var
(`GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false`) is set, the agent is
registered in the GE app, and — with `--smoke` — the agent answers **through Gemini Enterprise**
(same path as the UI) as well as directly through Agent Runtime. A green `--smoke` run means the
agent will work in the GE UI.

## Step 6 — Use it in Gemini Enterprise

GE app → **Agents** → *Argus — Life Sciences M&A Diligence*:

- Quick question: *"What is the regulatory status of Insmed's brensocatib in the US and EU?"*
- Target screening: *"We are a mid-cap oncology company looking for ADC assets in Phase 2+; screen 5 candidates."*
- Deep diligence: *"Run a full diligence whitepaper on Mersana Therapeutics."* → returns a PDF
  with charts stored in the `<project>-argus-artifacts` bucket.

---

## Updating / removing

| Action | Command |
| --- | --- |
| Redeploy after editing `app/` or `app/skills/` | `scripts/deploy.sh argus` |
| Refresh Science Skills to latest upstream | `scripts/sync_science_skills.sh --force` |
| Change contact in EDGAR UA | edit `EDGAR_USER_AGENT` in `.env`, redeploy |
| Remove the agent | `scripts/teardown.sh argus` (skills in Agent Registry are kept) |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| GE UI says *"I couldn't complete this request. If it needs a file, please attach it in the chat."* | GE's generic error wrapper. Run `scripts/verify.sh argus --smoke` — it checks that `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false` is set on the Reasoning Engine and calls the agent **through Gemini Enterprise**, the same path as the UI. If the env check fails, redeploy with `scripts/deploy.sh argus` (the flag is set by `deploy.sh`, `shared/cloudbuild.yaml` and the Terraform module). Root cause: GE forwards the end-user credential and the model call returns `401 UNAUTHENTICATED` without the flag. |
| `sync_science_skills.sh`: `gcloud alpha agent-registry … not found` | `gcloud components install alpha` / `gcloud components update`. |
| Agent says it cannot find skills / empty tool list | `scripts/sync_science_skills.sh --activate-all`; verify the agent identity has `roles/agentregistry.viewer` (`gcloud projects get-iam-policy $PROJECT_ID`). |
| EDGAR requests return `403` | SEC blocks generic user agents — set a real company + email in `EDGAR_USER_AGENT`. |
| Whitepaper generation times out in GE | Deep diligence runs 6 analysts; first run can take several minutes. Ask a quick question first to warm the instance. |
| `404 model gemini-3.7-flash` | Request access or set `ARGUS_EXTRA_ENV="ARGUS_MODEL=<available model>"`. |
