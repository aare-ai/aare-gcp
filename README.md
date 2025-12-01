# aare.ai - Google Cloud Functions Deployment

Google Cloud Functions implementation of the aare.ai Z3 SMT verification engine.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Google Cloud Functions                        │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    /verify endpoint                      │   │
│  │  ┌──────────┐  ┌──────────┐  ┌────────────────────┐     │   │
│  │  │   LLM    │→ │ Ontology │→ │   Z3 SMT Verifier  │     │   │
│  │  │  Parser  │  │  Loader  │  │  (Constraint Logic)│     │   │
│  │  └──────────┘  └──────────┘  └────────────────────┘     │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              ↓                                  │
│                    Google Cloud Storage                         │
│                   (aare-ai-ontologies/*.json)                   │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install)
- [Terraform](https://www.terraform.io/downloads) (for infrastructure deployment)
- Python 3.11+
- A GCP project with billing enabled

## Project Structure

```
aare-gcp/
├── main.py                      # Cloud Functions entry point
├── handlers/
│   ├── __init__.py
│   ├── llm_parser.py            # LLM output text parser
│   ├── formula_compiler.py      # Compile JSON formulas to Z3
│   ├── ontology_loader.py       # Loads rules from GCS
│   └── smt_verifier.py          # Z3 theorem prover engine
├── ontologies/                  # Compliance rule definitions
├── infra/
│   ├── main.tf                  # Terraform infrastructure
│   └── terraform.tfvars.example # Example variables
├── .github/
│   └── workflows/
│       └── deploy.yml           # CI/CD pipeline
├── requirements.txt             # Python dependencies
├── LICENSE
└── README.md
```

## Local Development

### 1. Create virtual environment

```bash
python -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

### 2. Set up authentication

```bash
gcloud auth application-default login
```

### 3. Run locally

```bash
functions-framework --target=verify --debug
```

The API will be available at `http://localhost:8080`

### 4. Test the endpoint

```bash
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{
    "llm_output": "Based on your DTI of 35% and FICO score of 720, you are approved for a $350,000 mortgage.",
    "ontology": "mortgage-compliance-v1"
  }'
```

## Deployment

### Option 1: GitHub Actions (Recommended)

1. **Set up Workload Identity Federation** (recommended over service account keys):

```bash
# Create a Workload Identity Pool
gcloud iam workload-identity-pools create "github-pool" \
  --location="global" \
  --display-name="GitHub Actions Pool"

# Create a provider
gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# Create a service account
gcloud iam service-accounts create github-actions-sa \
  --display-name="GitHub Actions Service Account"

# Grant necessary roles
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:github-actions-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/cloudfunctions.developer"

gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:github-actions-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.admin"

# Allow GitHub to impersonate the service account
gcloud iam service-accounts add-iam-policy-binding \
  github-actions-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/attribute.repository/aare-ai/aare-gcp"
```

2. **Add GitHub secrets**:
   - `GCP_PROJECT_ID`: Your GCP project ID
   - `GCP_WORKLOAD_IDENTITY_PROVIDER`: `projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider`
   - `GCP_SERVICE_ACCOUNT`: `github-actions-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com`

3. Push to `main` or manually trigger the workflow

### Option 2: Manual Deployment with gcloud

```bash
# Login
gcloud auth login

# Set project
gcloud config set project YOUR_PROJECT_ID

# Create GCS bucket for ontologies
gsutil mb -l us-west1 gs://aare-ai-ontologies-prod

# Deploy function
gcloud functions deploy aare-ai-verify-prod \
  --gen2 \
  --runtime=python311 \
  --region=us-west1 \
  --source=. \
  --entry-point=verify \
  --trigger-http \
  --allow-unauthenticated \
  --memory=2Gi \
  --timeout=30s \
  --set-env-vars="ONTOLOGY_BUCKET=aare-ai-ontologies-prod"
```

### Option 3: Terraform

```bash
cd infra

# Create terraform.tfvars
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your project ID

# Create state bucket first
gsutil mb -l us-west1 gs://aare-ai-terraform-state

# Initialize and apply
terraform init
terraform plan
terraform apply
```

## API Reference

### POST /

Verifies LLM output against compliance constraints.

**Request:**
```json
{
  "llm_output": "Your LLM-generated text here",
  "ontology": "mortgage-compliance-v1"
}
```

**Response:**
```json
{
  "verified": true,
  "violations": [],
  "warnings": ["Variables defaulted (not found in input): ['variable_name']"],
  "parsed_data": {
    "dti": 35,
    "credit_score": 720,
    "loan_amount": 350000
  },
  "ontology": {
    "name": "mortgage-compliance-v1",
    "version": "1.0.0",
    "constraints_checked": 5
  },
  "proof": {
    "method": "Z3 SMT Solver",
    "version": "4.12.1"
  },
  "verification_id": "uuid",
  "execution_time_ms": 45,
  "timestamp": "2024-01-01T00:00:00Z"
}
```

**Note:** The `warnings` field appears when variables couldn't be extracted from the LLM output and were defaulted.

## Formula Syntax

Constraints use structured JSON formulas that compile directly to Z3 expressions:

| Operator | Syntax | Example |
|----------|--------|---------|
| And | `{"and": [...]}` | `{"and": [{"<=": ["x", 10]}, {">=": ["y", 0]}]}` |
| Or | `{"or": [...]}` | `{"or": [{"==": ["approved", true]}, {">=": ["score", 700]}]}` |
| Not | `{"not": {...}}` | `{"not": {"==": ["has_phi", true]}}` |
| Implies | `{"implies": [A, B]}` | `{"implies": [{"==": ["is_denial", true]}, {"==": ["has_reason", true]}]}` |
| If-Then-Else | `{"ite": [cond, then, else]}` | `{"ite": [{">": ["score", 700]}, "approved", "denied"]}` |
| Equals | `{"==": [a, b]}` | `{"==": ["status", true]}` |
| Less/Greater | `{"<=": [a, b]}` | `{"<=": ["dti", 43]}` |
| Min/Max | `{"min": [a, b]}` | `{"<=": ["fee", {"min": [500, {"*": ["loan", 0.03]}]}]}` |

## Example Ontologies

| Ontology | Domain | Constraints | Description |
|----------|--------|-------------|-------------|
| `hipaa-v1` | Healthcare | 52 | HIPAA Privacy & Security Rule |
| `mortgage-compliance-v1` | Lending | 5 | ATR/QM, HOEPA, UDAAP, Reg B |
| `medical-safety-v1` | Healthcare | 5 | Drug interactions, dosing limits |
| `financial-compliance-v1` | Finance | 5 | Investment advice, disclaimers |
| `fair-lending-v1` | Lending | 5 | DTI limits, credit score requirements |

## Security

- Function is deployed with `--allow-unauthenticated` for public API access
- To require authentication, remove the `--allow-unauthenticated` flag and use IAM
- CORS restricted to aare.ai domains
- GCS bucket has uniform bucket-level access

### Requiring Authentication

```bash
# Deploy without --allow-unauthenticated
gcloud functions deploy aare-ai-verify-prod \
  --gen2 \
  --runtime=python311 \
  --region=us-west1 \
  --source=. \
  --entry-point=verify \
  --trigger-http \
  --memory=2Gi

# Generate an identity token for testing
TOKEN=$(gcloud auth print-identity-token)
curl -X POST https://YOUR_FUNCTION_URL \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"llm_output": "...", "ontology": "mortgage-compliance-v1"}'
```

## Monitoring

- View logs: `gcloud functions logs read aare-ai-verify-prod --gen2 --region=us-west1`
- Cloud Console: https://console.cloud.google.com/functions

## Cost Estimation

Using Cloud Functions (2nd gen):
- First 2 million invocations/month: Free
- Additional invocations: $0.40 per million
- Compute: $0.000016/GB-second
- Memory: 2GB function with 30s timeout max = $0.00096/invocation

Typical production usage (10,000 verifications/day): **~$5-15/month**

## License

MIT License - see [LICENSE](LICENSE) for details.
