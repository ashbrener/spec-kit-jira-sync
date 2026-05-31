# Contract — Jira Cloud REST endpoints

The REST surface the sink touches (API v3). Base = `$JIRA_BASE_URL`. Auth =
Basic `JIRA_EMAIL:JIRA_API_TOKEN`. Bodies/comments are ADF JSON (D2). No real
coordinates appear here; ids are config-resolved.

## Endpoints

| Purpose | Method + path | Notes |
|---------|---------------|-------|
| Auth probe | `GET /rest/api/3/myself` | startup sanity; failure → config error |
| Find issue by label | `GET /rest/api/3/search/jql?jql=…` | idempotency lookups via JQL |
| Read one issue | `GET /rest/api/3/issue/{key}?fields=status,labels,updated,parent` | drift fetch (status/updated/labels) |
| Create issue | `POST /rest/api/3/issue` | Epic / Story / Subtask (issue-type id from config) |
| Update issue | `PUT /rest/api/3/issue/{key}` | skip when no diff |
| List transitions | `GET /rest/api/3/issue/{key}/transitions` | resolve transition for target status |
| Transition | `POST /rest/api/3/issue/{key}/transitions` | `{transition:{id}}` |
| Add comment | `POST /rest/api/3/issue/{key}/comment` | ADF body |
| Link issues | `POST /rest/api/3/issueLink` | dependency links |

## Create payload shape (Story)

```jsonc
{ "fields": {
    "project":  { "key": "<KEY>" },
    "issuetype":{ "id":  "<story-id>" },
    "parent":   { "key": "<epic-key>" },   // group under repo Epic
    "summary":  "NNN — <title>",
    "description": { /* ADF */ },
    "labels": ["speckit-spec:NNN", "phase:<token>"]
} }
```

## Auth

`Authorization: Basic base64(<email>:<token>)` — supplied via curl `-u`; the
token never appears in a tracked file or in logs.

## Failure policy

- **Read unreadable** (401/403/404/network) → the read function returns **rc 3**;
  the engine fails closed for that spec (no write) and records an error.
- **429 / transient 5xx** → honor `Retry-After`, else jittered exponential
  backoff (~1s base, ×2, cap ~60s), **bounded** (default 5 tries); on exhaustion,
  fail closed for that spec (FR-022, SC-008).
- All credentials/transient errors are reported in the run summary, never
  silently swallowed (Principle VIII).

## Mocking

Every endpoint above has fixture responses under
`tests/fixtures/jira_responses/` (success, absent, drift-ahead, 401, 429) keyed
by method+URL for the curl-shim (D10).
