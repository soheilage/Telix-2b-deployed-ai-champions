# Deploy BioCompass to Gemini Enterprise — step by step

> Architecture, local development, evaluation and the full feature list are in
> [README.md](README.md). This page is only about getting the agent **into your
> Gemini Enterprise (GE) app** with as few manual steps as possible.

**What you get:** a Reasoning Engine on Agent Runtime (with Agent Identity), a logs
bucket, a BigQuery connection + `remote_models.text_embedding_model` (used for semantic
ranking), least-privilege IAM, and a GE registration named
**"BioCompass on Gemini Enterprise"**.

**Time:** ~15 min (one Cloud Build run). **Cost:** Agent Runtime is billed per
vCPU/GiB-hour only while serving; model calls are billed per token / image.

---

## Step 0 — Prerequisites (once per workstation)

```bash
gcloud --version            # ≥ 500
uv --version                # https://docs.astral.sh/uv/
gcloud auth login           # a project Owner / Editor+IAM Admin on the target project
```

You also need a **Gemini Enterprise app** in the project
(Console → *Gemini Enterprise* → *Apps* → *Create app*). Note its location
(`global`, `us` or `eu`).

## Step 1 — Configure

From the repository root:

```bash
cp .env.example .env
```

Edit `.env`:

| Key | Value for this agent |
| --- | --- |
| `PROJECT_ID` | your project, e.g. `eg-telix` |
| `REGION` | same geography as the GE app (`eu` → `europe-west4`; `us`/`global` → `us-central1`) |
| `GE_APP_ID` | leave empty — detected in Step 2 |
| `TF_STATE_BUCKET` | any globally-unique name; created if missing |
| `BIOCOMPASS_EXTRA_ENV` | *(optional)* e.g. `IMAGE_SIZE=1K;MAX_CRITIC_ROUNDS=1` for faster/cheaper runs |

Runtime defaults (`COORDINATOR_MODEL_NAME=gemini-3.1-pro-preview`,
`WORKER_MODEL_NAME=gemini-3.6-flash`, `IMAGE_MODEL_NAME=gemini-3-pro-image`,
`IMAGE_SIZE=2K`, `MAX_CRITIC_ROUNDS=2`) come from [`.env.example`](.env.example) in this
folder and can be overridden through `BIOCOMPASS_EXTRA_ENV`.

## Step 2 — Bootstrap the project (once per project, idempotent)

```bash
scripts/bootstrap.sh
```

Enables APIs, creates the `ge-agent-deployer` service account with the roles the pipeline
needs, creates the Terraform state bucket, lets the GE service agent call Agent Runtime,
and writes the detected `GE_APP_ID` into `.env`. If several GE apps exist it prints them
and asks you to pick one.

## Step 3 — Deploy and register

```bash
scripts/deploy.sh biocompass
```

This submits `shared/cloudbuild.yaml` to Cloud Build (running as the deployer SA):

1. `tf-apply` — Terraform creates/updates the Reasoning Engine, logs bucket, BigQuery
   connection + embedding model and IAM bindings for the agent identity.
2. `deploy-agent` — `agents-cli deploy` builds the container from `Dockerfile` and
   pushes the code to the Reasoning Engine.
3. `register-agent` — `agents-cli publish gemini-enterprise` registers it in your GE app
   (ADK registration, native `:streamQuery`).

Follow progress in the terminal or in Console → *Cloud Build* → *History*.
Add `--async` to return immediately; add `--no-register` to skip step 3.

## Step 4 — Verify

```bash
scripts/verify.sh biocompass            # engine + GE registration
scripts/verify.sh biocompass --smoke    # also sends a test prompt through Agent Runtime
```

Expected output:

```
✔ Reasoning Engine: projects/…/locations/europe-west4/reasoningEngines/… (updated …)
✔ registered in GE as 'BioCompass on Gemini Enterprise'  [ENABLED]
```

## Step 5 — Use it in Gemini Enterprise

Open your GE app → **Agents** → *BioCompass on Gemini Enterprise* and try:

- *"What is the mechanism of action of semaglutide? Give me 3 key references."*
- *"Run a PICO search strategy for SGLT2 inhibitors in heart failure with preserved EF."*
- *"Deep research: emerging safety signals for GLP-1 agonists in 2025."*
- *"Draw a concept figure of the JAK-STAT pathway."*

Admins can control which GE users see the agent in Console → *Gemini Enterprise* →
your app → *Agents* → *Permissions*.

---

## Updating / removing

| Action | Command |
| --- | --- |
| Redeploy after editing anything under `app/` | `scripts/deploy.sh biocompass` |
| Change models / image size | edit `BIOCOMPASS_EXTRA_ENV` in `.env`, redeploy |
| Raise NCBI rate limit | create a secret `pubmed-api-key`, then add `_SECRETS="PUBMED_API_KEY=pubmed-api-key"` to the `gcloud builds submit` call (see `shared/cloudbuild.yaml`) |
| Remove the agent completely | `scripts/teardown.sh biocompass` |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `tf-apply`: `Error creating Connection … 403` | IAM propagation for the deployer SA; wait 1–2 min and re-run. |
| `tf-apply`: BigQuery job `text-embedding-005 not found in <region>` | Choose a region where the model is served (e.g. `europe-west4`, `us-central1`) or pre-create the model. |
| `deploy-agent`: upload > 8 MB | The step writes a `.gcloudignore` that excludes `docs/ tests/ terraform/`; make sure you didn't add large files under `app/`. |
| GE shows the agent but every answer errors | `scripts/verify.sh biocompass --smoke`; then `gcloud logging read 'resource.type="aiplatform.googleapis.com/ReasoningEngine"' --project=$PROJECT_ID --limit=50` and look for `streaming_agent_run_with_events`. |
| `404 model gemini-3…` | Request Gemini 3 access for the project or override models via `BIOCOMPASS_EXTRA_ENV`. |
