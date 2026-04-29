# Agentic API Testing POC

## Context

This proof of concept is based on `doc/proposals/2026/gsoc/proposal_RajKishanSingh_agentic_api_testing.md`.

The requirement document proposes a four-stage pipeline:

1. Observe an API response
2. Assert and extract values from it
3. Chain those extracted values into downstream calls
4. Continuously build documentation/specs from observed traffic
5. Let AI assist with assertion generation, failure explanation, and natural-language chain construction

This POC implements the core service-layer foundation for that flow inside APIDash without introducing UI yet. The goal is to prove that the proposal can be represented with the existing APIDash request models, networking stack, agent framework, and environment-variable style interpolation.

## What This POC Implements

### 1. Selector and assertion engine

Implemented in:

- `lib/services/agentic_services/api_testing/api_testing_models.dart`
- `lib/services/agentic_services/api_testing/api_testing_engine.dart`

Supported selector types:

| Selector Type | Purpose | Example |
| --- | --- | --- |
| `jsonPath` | Resolve values from JSON response bodies | `$.data.token` |
| `regex` | Extract formatted values from response body text | `"token"\\s*:\\s*"([^"]+)"` |
| `header` | Read a response header case-insensitively | `Content-Type` |
| `statusCode` | Access HTTP status code | `200` |
| `responseTime` | Access latency in milliseconds | `245` |
| `bodySize` | Access body size in bytes | `512` |

Supported assertion operators:

- `exists`
- `equals`
- `notEquals`
- `contains`
- `matchesRegex`
- `gt`
- `gte`
- `lt`
- `lte`

Assertion groups support both:

- `and` logic: every assertion must pass
- `or` logic: at least one assertion must pass

### 2. Workflow chaining engine

Implemented in:

- `lib/services/agentic_services/api_testing/api_testing_engine.dart`

The workflow engine executes an ordered list of `ApiTestStep` objects and does the following for every step:

1. Substitutes runtime variables into the request using the same `{{VAR}}` syntax the proposal expects.
2. Executes the request through an injectable executor.
3. Evaluates assertion groups against the real response.
4. Extracts values from the response into a runtime variable store.
5. Aborts or continues depending on the step failure policy.
6. Records per-step results that can be used by UI or AI.

The engine is headless by design, so it can work with:

- the current Flutter UI later
- tests today
- future CLI/MCP integrations

There is also a default adapter:

- `ApiTestingRequestAdapter.execute(...)`

This adapter reuses APIDash's existing `sendHttpRequest(...)` networking path, so the POC is already aligned with the current execution stack.

### 3. Continuously evolving OpenAPI 3.1 document

Implemented in:

- `lib/services/agentic_services/api_testing/api_testing_spec.dart`

The spec accumulator observes real responses and merges them into an OpenAPI 3.1 compatible document structure.

Current capabilities:

- Builds `paths -> method -> responses -> content -> schema`
- Tracks schemas per status code
- Infers primitive and container types
- Marks fields as optional by omitting them from `required` when absent in some runs
- Marks nullable fields using JSON Schema / OpenAPI 3.1 style type unions, for example `["string", "null"]`
- Stores latest examples from observed responses
- Detects endpoint gaps through `x-apidash-gaps`

Example behavior:

- Run 1 sees `{ "id": 1, "email": "raj@example.com" }`
- Run 2 sees `{ "id": 2, "email": "jay@example.com", "avatar": "https://..." }`
- Run 3 sees `{ "id": 3, "email": "arjun@example.com", "avatar": null }`

The merged schema becomes:

```json
{
  "type": "object",
  "properties": {
    "avatar": {
      "type": ["string", "null"],
      "example": null
    },
    "email": {
      "type": "string",
      "example": "arjun@example.com"
    },
    "id": {
      "type": "integer",
      "example": 3
    }
  },
  "required": ["email", "id"],
  "example": {
    "id": 3,
    "email": "arjun@example.com",
    "avatar": null
  }
}
```

### 4. AI assist scaffolding

Implemented in:

- `lib/services/agentic_services/api_testing/api_testing_ai.dart`
- `lib/services/agentic_services/agents/api_assertion_generation.dart`
- `lib/services/agentic_services/agents/api_failure_explanation.dart`
- `lib/services/agentic_services/agents/api_chain_builder.dart`
- `lib/templates/system_prompt_templates/api_assertion_generation_prompt.dart`
- `lib/templates/system_prompt_templates/api_failure_explanation_prompt.dart`
- `lib/templates/system_prompt_templates/api_chain_builder_prompt.dart`

This part of the POC does not add UI yet, but it wires the proposal into APIDash's existing `AIAgent` model.

The POC now includes:

- `ApiAssertionGenerationAgent`
- `ApiFailureExplanationAgent`
- `ApiChainBuilderAgent`

And helper entry points in:

- `lib/services/agentic_services/apidash_agent_calls.dart`

New helper functions:

- `generateApiAssertionsFromResponse(...)`
- `explainApiWorkflowFailure(...)`
- `buildApiWorkflowChainFromPrompt(...)`

The AI payload/parser layer now standardizes:

- assertion suggestion parsing
- failure explanation parsing
- chain plan parsing
- prompt input generation from real APIDash request/response models

This is important because it means the AI layer is not free-form anymore. It is constrained to structured outputs that the app can validate before using.

## Data Model Overview

### Core workflow DSL

Main classes:

- `ApiTestSelector`
- `ApiTestAssertion`
- `ApiTestAssertionGroup`
- `ApiTestExtraction`
- `ApiTestStep`
- `ApiTestOperationMetadata`
- `ApiTestExecutionResult`
- `ApiTestStepResult`
- `ApiTestRunResult`

These types are intentionally lightweight and service-oriented so they can be consumed by:

- a future workflow editor UI
- run history views
- AI diagnostics
- export flows

### AI output models

Main classes:

- `ApiTestAssertionSuggestion`
- `ApiTestFailureExplanation`
- `ApiTestChainPlan`
- `ApiTestChainPlanStep`

## Example Workflow in This POC

The tests demonstrate a realistic chain:

1. A login request runs with `{{AUTH_USER}}` injected into headers.
2. Assertions confirm `statusCode == 200` and `$.data.token EXISTS`.
3. `$.data.token` is extracted into `AUTH_TOKEN`.
4. A second request automatically receives `Authorization: Bearer {{AUTH_TOKEN}}`.
5. Both responses are added into the evolving OpenAPI document.

This is exactly the proposal's login -> authenticated call flow, represented using current APIDash models.

## Test Coverage

Implemented in:

- `test/services/agentic_api_testing_poc_test.dart`

Covered scenarios:

- selector resolution for JSONPath, header, regex, status code, and response time
- assertion group evaluation
- runtime variable extraction and downstream substitution
- abort-on-failure workflow gating
- OpenAPI schema merge behavior for optional + nullable fields
- gap detection
- AI parser support for structured JSON outputs wrapped in markdown fences

Verified command:

```bash
flutter test test/services/agentic_api_testing_poc_test.dart
```

## Why This POC Fits APIDash

This POC intentionally reuses the current architecture rather than creating a parallel stack.

It builds on:

- `RequestModel`
- `HttpRequestModel`
- `HttpResponseModel`
- `sendHttpRequest(...)`
- `{{VAR}}` substitution semantics
- `AIAgent` / `AIAgentService`

That makes the next integration steps much cheaper than starting from a separate prototype.

## Current Limits

This is a POC, so some things are intentionally scoped down.

### Implemented but limited

- JSONPath support is a practical subset:
  - dot access
  - bracket property access
  - array indexes
- Failure policy currently supports:
  - `abort`
  - `continue`
- Spec export is currently JSON-structure generation, not UI download/export plumbing

### Not implemented yet

- UI panels for attaching selectors/assertions to requests
- collection persistence for workflow steps
- run history persistence for workflow runs
- YAML export
- richer selector types such as body substring windows or advanced JSONPath filters
- visual diffing of evolving schemas
- automatic acceptance/edit/reject UI for AI-generated assertion sets
- workflow canvas/editor

## Recommended Next Steps

### Phase 1

- Add persistence for workflow step configuration in collection data
- Add UI for selectors, assertions, and extraction rules
- Show `ApiTestStepResult` in a run details pane

### Phase 2

- Surface generated assertion suggestions in the response UI
- Show AI failure explanation in the run result pane
- Add user confirmation flow for AI-generated chains

### Phase 3

- Persist the accumulated OpenAPI document
- Add JSON/YAML export buttons
- Add spec coverage dashboard and endpoint gap highlighting

## File Map

### Core POC

- `lib/services/agentic_services/api_testing/api_testing.dart`
- `lib/services/agentic_services/api_testing/api_testing_models.dart`
- `lib/services/agentic_services/api_testing/api_testing_engine.dart`
- `lib/services/agentic_services/api_testing/api_testing_spec.dart`
- `lib/services/agentic_services/api_testing/api_testing_ai.dart`

### AI integration

- `lib/services/agentic_services/agents/api_assertion_generation.dart`
- `lib/services/agentic_services/agents/api_failure_explanation.dart`
- `lib/services/agentic_services/agents/api_chain_builder.dart`
- `lib/services/agentic_services/apidash_agent_calls.dart`

### Prompt templates

- `lib/templates/system_prompt_templates/api_assertion_generation_prompt.dart`
- `lib/templates/system_prompt_templates/api_failure_explanation_prompt.dart`
- `lib/templates/system_prompt_templates/api_chain_builder_prompt.dart`

### Tests

- `test/services/agentic_api_testing_poc_test.dart`

## Final Summary

This POC proves that Raj Kishan Singh's proposal is technically viable inside the current APIDash codebase.

The important outcome is not just that the parts exist independently, but that they already connect:

- selectors evaluate real responses
- extractions feed a runtime store
- chained requests consume those values
- every observed response contributes to an evolving OpenAPI document
- AI agents can now be plugged into the same run context with structured, validated outputs

That gives APIDash a solid base for turning the proposal into a full product feature instead of a disconnected prototype.