# Deploy PaperBanana to Gemini Enterprise — step by step

> Architecture, attribution (port of Google Research's PaperVizAgent), local
> development and evaluation are in [README.md](README.md). This page is only
> about getting the agent **into your Gemini Enterprise (GE) app**.

**What you get:** a Reasoning Engine on Agent Runtime (with Agent Identity), a logs
bucket, least-privilege IAM, and a GE registration named
**"PaperBanana on Gemini Enterprise"**. Users attach a paper PDF (or paste a section /
table) in GE chat and iterate on a publication-quality figure.

**Time:** ~12 min (one Cloud Build run).

---

## Step 0 — Prerequisites (once per workstation)

```bash
gcloud --version            # ≥ 500
uv --version                # https://docs.astral.sh/uv/  (only for --smoke)
gcloud auth login           # a project Owner / Editor+IAM Admin on the target project
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
| `PAPERBANANA_EXTRA_ENV` | *(optional)* `IMAGE_SIZE=2K;MAX_CRITIC_ROUNDS=2` for faster iterations (default is 4K / 3 rounds) |

Defaults: `PLANNER_MODEL_NAME=gemini-3.1-pro-preview`, `IMAGE_MODEL_NAME=gemini-3-pro-image`,
`IMAGE_SIZE=4K`, `MAX_CRITIC_ROUNDS=3` (see [`.env.example`](.env.example)).
`deploy.sh` always sets `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false`,
which the image model call needs when running under Agent Identity.

## Step 2 — Bootstrap the project (once per project, idempotent)

```bash
scripts/bootstrap.sh
```

## Step 3 — Deploy and register

```bash
scripts/deploy.sh paperbanana
```

Cloud Build (as the deployer SA): Terraform → `agents-cli deploy` →
`agents-cli publish gemini-enterprise`. Add `--async` to return immediately,
`--no-register` to skip the GE step.

## Step 4 — Verify

```bash
scripts/verify.sh paperbanana
scripts/verify.sh paperbanana --smoke   # text-only prompt, no image generated
```

Expected:

```
✔ Reasoning Engine: projects/…/reasoningEngines/… (updated …)
✔ GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false
✔ registered in GE as 'PaperBanana on Gemini Enterprise'  [ENABLED]
✔ GE path works: "AGENT OK"        # with --smoke
```

`verify.sh` checks four things: the Reasoning Engine exists, the required runtime env var
(`GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false`) is set, the agent is
registered in the GE app, and — with `--smoke` — the agent answers **through Gemini Enterprise**
(same path as the UI) as well as directly through Agent Runtime. A green `--smoke` run means the
agent will work in the GE UI.

## Step 5 — Use it in Gemini Enterprise

GE app → **Agents** → *PaperBanana on Gemini Enterprise*:

> **A paper PDF is required.** PaperBanana is a *paper-to-figure* agent: the planner,
> stylist and critic all read the attached PDF. Without an attachment it will (by design)
> ask you to attach one.

1. Attach a research paper PDF in the composer (any open-access trial or methods paper works).
2. *"Create a publication-style figure of the study design and patient flow described in this paper."*
3. Follow up: *"Make the colour palette colour-blind safe and enlarge the panel labels."*
   (edit mode keeps the previous image as reference).

---

## Updating / removing

| Action | Command |
| --- | --- |
| Redeploy after editing `app/` or `style_guide.md` | `scripts/deploy.sh paperbanana` |
| Faster / cheaper renders | `PAPERBANANA_EXTRA_ENV="IMAGE_SIZE=2K;MAX_CRITIC_ROUNDS=1"` in `.env`, redeploy |
| Remove the agent | `scripts/teardown.sh paperbanana` |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| GE UI says *"I couldn't complete this request…"* | GE's generic error wrapper. Run `scripts/verify.sh paperbanana --smoke` — it checks the runtime env var and calls the agent **through Gemini Enterprise** (same path as the UI). If it fails, redeploy with `scripts/deploy.sh paperbanana`. |
| Figure request times out in GE | Lower `IMAGE_SIZE` to `2K` and `MAX_CRITIC_ROUNDS` to `1–2`; 4K × 3 rounds can exceed 2–3 min. |
| `403` calling the image model | Confirm the `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false` env var is present on the Reasoning Engine (it is set by `deploy.sh`) and that the agent identity has `roles/aiplatform.expressUser` (Terraform). |
| `404 model gemini-3-pro-image` | Request access to the image model in the project. |
| Registration `403` | Deployer SA needs `roles/discoveryengine.agentspaceAdmin` (granted by bootstrap). |
