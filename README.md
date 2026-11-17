# StackForce Sync — Salesforce ↔ Slack Bidirectional Case Integration

> **Real-time, bidirectional integration** that pushes Critical-priority Salesforce Cases to a designated Slack channel and lets Slack users claim or escalate them — with every action reflected back in Salesforce instantly.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Data Flow](#data-flow)
3. [Metadata Inventory](#metadata-inventory)
4. [Prerequisites](#prerequisites)
5. [Setup & Deployment](#setup--deployment)
6. [Configuration Reference](#configuration-reference)
7. [Security Model](#security-model)
8. [Operational Notes](#operational-notes)
9. [Roadmap — Next Features](#roadmap--next-features)
10. [Contributing](#contributing)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        SALESFORCE                           │
│                                                             │
│  Case (Critical)  ──► Record-Triggered Flow                 │
│                            │                                │
│                            ▼                                │
│                   SlackAlertQueueable                       │
│                            │                                │
│                            ▼                                │
│                   SlackCalloutService ──► Named Credential  │
│                            │               (Slack_API)      │
│                            ▼                                │
│                   Slack_API / chat.postMessage              │
│                                                             │
│  ◄── REST endpoint:  SlackWebhookListener                   │
│        /slack/events/*                                      │
│              │                                              │
│              ▼                                              │
│    Slack_Action_Event__e  (Platform Event)                  │
│              │                                              │
│              ▼                                              │
│    SlackActionEventTrigger                                  │
│              │                                              │
│              ├─► Update Case  (Status / Claimed_By)         │
│              └─► SlackMessageUpdateQueueable                │
│                        │                                    │
│                        ▼                                    │
│               Slack_API / chat.update                       │
└─────────────────────────────────────────────────────────────┘
                              ▲  ▼
                         SLACK CHANNEL
                       #urgent-incidents
```

---

## Data Flow

### Outbound (Salesforce → Slack)

| Step | Component | Detail |
|------|-----------|--------|
| 1 | **Record-Triggered Flow** `Push_Case_to_Slack` | Fires `after insert/update` when `Priority = Critical` AND `Slack_Message_TS__c` is null (prevents duplicate posts) |
| 2 | **`SlackAlertQueueable`** | Wraps the callout in a Queueable so it executes outside the trigger transaction |
| 3 | **`SlackCalloutService.sendCaseAlert()`** | Fetches the active `Slack_Routing_Rule__mdt` record, merges case data into the JSON Block Kit template, and POSTs to `chat.postMessage` |
| 4 | **Case update** | Saves `Slack_Channel_Id__c`, `Slack_Message_TS__c`, and `Slack_Sync_Status__c = Delivered` |
| 5 | **`Integration_Log__c`** | Full request + response audit trail written |

### Inbound (Slack → Salesforce)

| Step | Component | Detail |
|------|-----------|--------|
| 1 | Slack sends a `block_actions` POST to the **Experience Cloud Site** endpoint `/slack/events/*` | Triggered by user clicking "Claim Case" or "Escalate" |
| 2 | **`SlackWebhookListener`** | Verifies HMAC-SHA256 signature, parses payload, publishes `Slack_Action_Event__e` |
| 3 | **`SlackActionEventTrigger`** | Subscribes to the Platform Event; updates `Case.Status` and `Case.Claimed_By_Slack_User__c` |
| 4 | **`SlackMessageUpdateQueueable`** | Calls `chat.update` to replace the original message: hides action buttons, appends a status banner |

---

## Metadata Inventory

### Apex Classes

| Class | Sharing | Purpose |
|-------|---------|---------|
| `SlackCalloutService` | `with sharing` | Core outbound HTTP logic; shared audit log writer |
| `SlackAlertQueueable` | `with sharing` | Defers `sendCaseAlert()` callout; exposes `@InvocableMethod` for Flow |
| `SlackMessageUpdateQueueable` | `with sharing` | Updates existing Slack message after a user action |
| `SlackWebhookListener` | `without sharing` (global REST) | Receives Slack interaction callbacks; validates signature |

### Apex Trigger

| Trigger | Object | Events |
|---------|--------|--------|
| `SlackActionEventTrigger` | `Slack_Action_Event__e` | `after insert` |

### Flow

| Flow | Type | Trigger |
|------|------|---------|
| `Push_Case_to_Slack` | Record-Triggered (AutoLaunched) | Case after save — Priority = Critical, Slack_Message_TS__c is null |

### Custom Objects / Fields

| Object / Field | Type | Purpose |
|----------------|------|---------|
| `Integration_Log__c` | Custom Object | Bidirectional HTTP audit trail |
| `Slack_Action_Event__e` | Platform Event (High Volume) | Decouples webhook receipt from case update |
| `Slack_Routing_Rule__mdt` | Custom Metadata Type | Admin-managed channel routing & Block Kit templates per priority |
| `Case.Slack_Channel_Id__c` | Text(50) | Slack channel that received the alert |
| `Case.Slack_Message_TS__c` | Text(50) | Slack message timestamp (used as message ID for updates) |
| `Case.Slack_Sync_Status__c` | Picklist | `Not Sent` / `Delivered` / `Acknowledged` / `Failed` |
| `Case.Claimed_By_Slack_User__c` | Text(255) | Slack username of the agent who claimed the case |

### Named & External Credentials

| Credential | Purpose |
|------------|---------|
| `Slack_API` (Named Credential) | Base URL `https://slack.com/api`; references `Slack_External_Cred` |
| `Slack_External_Cred` (External Credential) | Holds the Bot Token `Authorization: Bearer xoxb-…` header |

### Permission Set

`Slack_Integration_Access` — grants access to the External Credential principal and the Platform Event object. Assign to the **Integration User** or any admin running the integration.

---

## Prerequisites

- **Salesforce CLI** (`sf`) — [Install guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_install_cli.htm)
- A **Salesforce org** (Developer Edition or Sandbox) with **API access** enabled
- A **Slack App** with:
  - Bot Token scope: `chat:write`, `chat:write.public`
  - **Interactivity** enabled, Request URL pointed at your Salesforce Experience Site URL
- **Experience Cloud Site** (`Slack_Webhook`) deployed and **active** (provides the public REST endpoint)

---

## Setup & Deployment

### 1 — Clone & Authorize

```bash
git clone https://github.com/YOUR_USERNAME/stackforce-sync.git
cd stackforce-sync
sf org login web --alias myOrg
```

### 2 — Deploy Metadata

```bash
sf project deploy start --manifest manifest/package.xml --target-org myOrg
```

### 3 — Set Credentials (do NOT commit real values)

After deployment, go to **Setup → Named Credentials → Slack External Cred** and enter:

| Parameter | Value |
|-----------|-------|
| `Authorization` | `Bearer xoxb-YOUR-SLACK-BOT-TOKEN` |

Then go to **Setup → Custom Metadata Types → Slack Routing Rule → Critical Rule** and set:

| Field | Value |
|-------|-------|
| `Signing_Secret__c` | Your Slack App Signing Secret |
| `Slack_Channel_Id__c` | Target channel ID (e.g. `C0123456789`) |

### 4 — Assign Permission Set

```bash
sf org assign permset --name Slack_Integration_Access --target-org myOrg
```

### 5 — Configure Slack App Interactivity

In your Slack App settings:

- **Interactivity Request URL**: `https://YOUR-SITE-DOMAIN.my.site.com/services/apexrest/slack/events/`
- Ensure the **Bot Token Scopes** include `chat:write` and `chat:write.public`

### 6 — Verify

Create a Case with **Priority = Critical** in Salesforce. The alert should appear in the configured Slack channel within seconds.

---

## Configuration Reference

The `Slack_Routing_Rule__mdt` custom metadata type controls all runtime configuration. No code changes are needed to add a new priority channel.

| Field | Description |
|-------|-------------|
| `Priority__c` | Matches `Case.Priority` (e.g. `Critical`) |
| `Is_Active__c` | Toggle a rule on/off without deleting it |
| `Slack_Channel_Id__c` | Target Slack channel ID |
| `Signing_Secret__c` | Slack App Signing Secret for signature verification |
| `Message_Template__c` | Full Block Kit JSON with `{{TOKEN}}` placeholders |

### Supported Template Tokens

| Token | Replaced With |
|-------|--------------|
| `{{CHANNEL_ID}}` | Slack channel ID |
| `{{CASE_ID}}` | Salesforce Case record ID |
| `{{CASE_NUMBER}}` | Case number (e.g. `00001029`) |
| `{{PRIORITY}}` | Case priority |
| `{{STATUS}}` | Case status |
| `{{ACCOUNT_NAME}}` | Account name or `N/A` |
| `{{CASE_URL}}` | Direct link to the Case record |
| `{{SUBJECT}}` | Case subject |

---

## Security Model

| Concern | Mitigation |
|---------|-----------|
| Slack token | Stored in External Credential (encrypted at rest); never in source code |
| Signing secret | Stored in Custom Metadata (admin-only field); placeholder in source |
| Webhook authenticity | HMAC-SHA256 signature verified on every inbound request |
| Replay attacks | Timestamp freshness check (±5 minutes) on every inbound request |
| Public endpoint | Experience Cloud Guest User profile has minimum permissions; only the REST class is exposed |
| DML in trigger | Trigger performs DML after Platform Event (safe, async context) |

> [!CAUTION]
> Never commit real Slack Bot Tokens or Signing Secrets to version control. The placeholder values in this repository (`REPLACE_WITH_YOUR_SLACK_BOT_TOKEN`, `REPLACE_WITH_YOUR_SLACK_SIGNING_SECRET`) must be replaced **after deployment** via Setup UI only.

---

## Operational Notes

- **Duplicate prevention**: The Flow entry condition (`Slack_Message_TS__c IS NULL`) and the `sendCaseAlert` guard (`Slack_Sync_Status__c == 'Delivered'`) together ensure a case is only posted to Slack once, even if re-triggered by an unrelated update.
- **Idempotent updates**: `SlackMessageUpdateQueueable` skips the callout if `Channel_Id` or `Message_TS` are blank, logging the skip for observability.
- **Platform Event fanout**: Using `Slack_Action_Event__e` decouples the synchronous REST response (must return 200 within 3 s) from the case DML and outbound callout.
- **Audit trail**: Every inbound and outbound interaction writes an `Integration_Log__c` record with full request/response payload (capped at 32 768 characters).

## Contributing

1. Fork the repo and create a feature branch
2. Deploy to a scratch org: `sf org create scratch --definition-file config/project-scratch-def.json --alias scratch1`
3. Make changes, write Apex tests (minimum 75% coverage)
4. Open a pull request with a description of the change and screenshots of the Slack interaction

---

*Built with the Salesforce CLI, Apex, Platform Events, and Slack Block Kit.*
