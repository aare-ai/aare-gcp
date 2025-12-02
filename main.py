"""
aare.ai - Google Cloud Functions main entry point
Verification endpoint using Z3 theorem prover
"""
import functions_framework
import json
import uuid
from datetime import datetime

from aare_core import OntologyLoader, LLMParser, SMTVerifier

# Initialize components
ontology_loader = OntologyLoader()
llm_parser = LLMParser()
smt_verifier = SMTVerifier()

# CORS allowed origins
ALLOWED_ORIGINS = [
    "https://aare.ai",
    "https://www.aare.ai",
    "http://localhost:8000",
    "http://localhost:3000"
]


def get_cors_headers(request) -> dict:
    """Generate CORS headers based on request origin"""
    origin = request.headers.get("Origin", "")

    # Check if origin is allowed
    if origin in ALLOWED_ORIGINS:
        allowed_origin = origin
    else:
        allowed_origin = ALLOWED_ORIGINS[0]  # Default to primary domain

    return {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": allowed_origin,
        "Access-Control-Allow-Headers": "Content-Type,x-api-key,Authorization",
        "Access-Control-Allow-Methods": "OPTIONS,POST"
    }


@functions_framework.http
def verify(request):
    """
    HTTP Cloud Function for aare.ai verification

    Request body:
    {
        "llm_output": "text to verify",
        "ontology": "ontology-name-v1"
    }
    """
    cors_headers = get_cors_headers(request)

    # Handle CORS preflight
    if request.method == "OPTIONS":
        return ("", 204, cors_headers)

    # Only allow POST
    if request.method != "POST":
        return (
            json.dumps({"error": "Method not allowed"}),
            405,
            cors_headers
        )

    try:
        # Parse request body
        request_json = request.get_json(silent=True)

        if not request_json:
            return (
                json.dumps({"error": "Invalid JSON in request body"}),
                400,
                cors_headers
            )

        llm_output = request_json.get("llm_output", "")
        ontology_name = request_json.get("ontology", "mortgage-compliance-v1")

        if not llm_output:
            return (
                json.dumps({"error": "llm_output is required"}),
                400,
                cors_headers
            )

        # Load ontology
        ontology = ontology_loader.load(ontology_name)

        # Parse LLM output into structured data
        extracted_data = llm_parser.parse(llm_output, ontology)

        # Verify constraints using Z3
        verification_result = smt_verifier.verify(extracted_data, ontology)

        # Build response
        response_body = {
            "verified": verification_result["verified"],
            "violations": verification_result["violations"],
            "parsed_data": extracted_data,
            "ontology": {
                "name": ontology["name"],
                "version": ontology["version"],
                "constraints_checked": len(ontology["constraints"])
            },
            "proof": verification_result["proof"],
            "solver": "Constraint Logic",
            "verification_id": str(uuid.uuid4()),
            "execution_time_ms": verification_result["execution_time_ms"],
            "timestamp": datetime.utcnow().isoformat()
        }

        return (json.dumps(response_body), 200, cors_headers)

    except Exception as e:
        return (
            json.dumps({
                "error": str(e),
                "type": type(e).__name__
            }),
            500,
            cors_headers
        )
