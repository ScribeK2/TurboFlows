# TurboFlows Workflow Import Guide

> **This guide describes the LEGACY import formats** — JSON without a
> `schema_version`, plus YAML, CSV and Markdown. They still work and are not
> deprecated.
>
> **For a file written by an AI agent, use the strict dialect instead.** It is
> described by two generated artifacts, not by this document:
> `public/schemas/turboflows-workflow-v1.json` (the JSON Schema) and the
> copyable prompt on `/workflows/import`. Both are generated from the models, so
> they cannot drift from what the app accepts. The strict path validates before
> writing anything and reports every problem at once; the legacy path described
> here coerces silently and imports what it can.
>
> **Verify by running, not by reading.** Every prior revision of this file
> claimed rich text "supports Markdown". It never has — there is no Markdown
> converter anywhere in the app, and the text is stored verbatim as HTML, so
> `**bold**` renders with the asterisks showing. That claim survived several
> "verified against the code" passes because the tables were read rather than
> executed.

> **Verified against the code on 2026-08-30.** Every example below was run
> through `WorkflowImporter` and imports cleanly; every field table was checked
> against `StepFieldMap` and the model's `VALID_*` constants. Re-verify by
> running the examples rather than reading them — the previous revision of this
> guide documented an escalate default that failed every import that used it.

This guide covers everything you need to write a workflow file that imports cleanly into TurboFlows. It covers all four supported formats (JSON, CSV, YAML, Markdown), every step type with its required and optional fields, and the transition system that connects steps together.

---

## What every import does now, in every format

- **Imports land as `status: "draft"`.** They previously claimed `published`
  without ever passing `WorkflowPublisher` — no version, no `published_version`.
  An import needs an explicit publish.
- **Imported drafts never expire.** `CleanupDraftsJob` sweeps expired drafts
  daily; imports carry no `draft_expires_at`, so it does not touch them.
- **A failed import writes nothing.** The whole import runs in one transaction,
  so a failure part-way no longer leaves a half-built workflow behind.
- **JSON and YAML carry placement**: `groups` (name paths from the root, e.g.
  `"Support / Tier 2"`), `folder`, and `tags`. An unknown group, or one you do
  not have access to, fails the import rather than being ignored. CSV and
  Markdown are flat formats and carry none of it.
- **Rich text is HTML.** `instructions`, `content`, `notes` and `description` are
  stored as written. Use `<p>`, `<strong>`, `<em>`, `<ul>/<ol>/<li>`, `<a href>`.
  Markdown is not converted.
- **Loops are allowed.** A workflow may return to an earlier step; what is
  refused is a loop with no way out, where some step can no longer reach a
  `resolve`.

---

## Quick Start

All workflows import into **Graph Mode**, where each step explicitly declares which step(s) come next via `transitions`. Every non-terminal step needs at least one transition. `resolve` steps are terminal and must not have transitions.

The fastest path to a working import:

1. Give each step a unique `id` (any string — `"step-1"`, `"greeting"`, a UUID, etc.).
2. Add a `transitions` array to every step except `resolve` steps.
3. Each transition needs at minimum a `target_uuid` pointing to another step's `id`.
4. End your workflow with a `resolve` step (no transitions needed).

If you omit transitions entirely, the importer generates them in sequential order (step 1 → step 2 → step 3 → ...), which is all a sequential workflow needs.

---

## Workflow Structure

Every import file produces a workflow with these top-level fields:

| Field | Required | Description |
|-------|----------|-------------|
| `title` | Yes | Workflow name. JSON/YAML require this; CSV uses the first row's `workflow_title` column; Markdown uses the `# H1` heading. |
| `description` | No | Workflow description. |
| `graph_mode` | No | Set to `true` explicitly, or omit — the importer always imports as graph mode. |
| `start_node_uuid` | No | The `id` of the first step. Defaults to the first step in the array if omitted. |
| `steps` | Yes | Array of step objects (see below). |

---

## Fields Every Step Accepts

These apply to all seven step types and are easy to miss — they are not repeated
in the per-type tables below.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `type` | Yes | — | See Step Types Reference |
| `title` | Yes | — | Display name. Defaults to `"Step N"` if omitted. |
| `id` | No | generated | Any string. Transitions reference it. A UUID is generated if omitted. |
| `help_text` | No | — | Short guidance shown with the step at run time. Max 500 characters. |
| `reference_url` | No | — | A "More info" link rendered beside the step. |

### `description` is a resolve-only field

Earlier revisions of this guide listed `description` on question, action, message,
escalate and sub_flow. **It is silently dropped on all of them** — only
`Steps::Resolve` has it, as rich text. `Steps::Question` does not even respond to
the attribute. Put per-step guidance in `help_text` instead, which every type
accepts.

## Step Types Reference

There are **seven** step types: question, action, message, escalate, resolve,
sub_flow and form. Every step requires `type` and `title`. All other fields depend
on the step type.

### question

Collects input from the user running the simulation.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `type` | Yes | — | `"question"` |
| `title` | Yes | — | Display name for the step |
| `question` | **Yes** | — | The question text shown to the user. **Step is flagged incomplete if blank.** |
| `answer_type` | No | `"text"` | One of: `text`, `yes_no`, `multiple_choice`, `number`, `date`, `dropdown` |
| `variable_name` | No | `""` | Variable name to store the answer (used for branching and interpolation) |
| `options` | No | `[]` | Array of `{ "label": "...", "value": "..." }` objects. Required when `answer_type` is `multiple_choice` or `dropdown`. |
| `can_resolve` | No | `false` | When `true`, the scenario player shows a "This resolved the issue" button alongside Continue. |

### action

Displays instructions for the agent to follow. The user clicks "Continue" to proceed.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `type` | Yes | — | `"action"` |
| `title` | Yes | — | Display name |
| `instructions` | **Yes** | — | Instruction text. **HTML, not Markdown** (see below), with `{{variable}}` interpolation. **Step is flagged incomplete if blank.** |
| `can_resolve` | No | `false` | When `true`, the scenario player shows a "This resolved the issue" button alongside Continue. Clicking it ends the scenario with `resolution_type: "success"` and records which step resolved the issue. |
| `jumps` | No | `[]` | Array of `{ "condition": "...", "next_step_id": "..." }`. Evaluated by `StepResolver#check_jumps` before ordinary transitions. Must be an array — anything else is ignored. No builder UI authors these yet; import is currently the only way to set them. |

### message

Displays informational content. Similar to action but styled differently — used for announcements and read-only information.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `type` | Yes | — | `"message"` |
| `title` | Yes | — | Display name |
| `content` | No | `""` | The message text to display. **HTML, not Markdown** (see below), with `{{variable}}` interpolation |
| `can_resolve` | No | `false` | When `true`, the scenario player shows a "This resolved the issue" button alongside Continue. Clicking it ends the scenario with `resolution_type: "success"` and records which step resolved the issue. |
| `jumps` | No | `[]` | As for `action`, above. |

### decision *(not a step type — accepted and converted)*

**There is no decision step.** `decision` and `simple_decision` are accepted as
*input dialects* and converted to `question` steps on import, with a warning:
"Converted deprecated 'decision' step 'X' to question". The step's `title` becomes
the question text. They are documented here so old files keep importing, not
because you should write new ones — use a `question` with conditional
`transitions` instead.

Routes the workflow to different steps based on conditions evaluated against stored variables.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `type` | Yes | — | `"decision"` |
| `title` | Yes | — | Display name |
| `branches` | No | `[]` | Array of `{ "condition": "...", "path": "Step Title" }`. Converted to conditional transitions on import. |
| `else_path` | No | `""` | Fallback step title when no branch condition matches. Converted to an unconditional transition on import. |

**Conditions** use the format `variable_name == 'value'` or `variable_name != 'value'`. Compound conditions use `&&` and `||` (e.g., `priority == 'critical' && customer_type == 'enterprise'`).

**With explicit transitions** (recommended): Skip `branches`/`else_path` and use the `transitions` array with conditions directly. See the Transitions section below.

**Flagged incomplete** if: no transitions AND no branches with content.

### escalate

Transfers the interaction to another department, supervisor, channel, or ticket system.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `type` | Yes | — | `"escalate"` |
| `title` | Yes | — | Display name |
| `target_type` | No | `""` | One of: `team`, `queue`, `supervisor`, `channel`, `department`, `ticket`. All six are equally valid — `Steps::Escalate::VALID_TARGET_TYPES`. No conversion happens; earlier revisions called `team` and `queue` "legacy", which they are not. |
| `target_value` | No | `""` | Identifier for the specific target (e.g., team name, channel ID). Also accepts `target_id` as an alias. |
| `priority` | No | `"medium"` | One of: `low`, `medium`, `high`, `urgent`, `critical` — `Steps::Escalate::VALID_PRIORITIES`. `normal` is accepted and converted to `medium`. Matching ignores case and surrounding whitespace. |
| `reason_required` | No | `false` | When `true`, the agent must provide a reason when reaching this step. |
| `notes` | No | `""` | Rich text notes for the escalation (e.g., reason, context). Also accepts `reason` as an alias. |

**Note:** Escalate steps are NOT automatically terminal — they can continue to subsequent steps via transitions.

### resolve

Ends the workflow with a resolution status. This is a **terminal step** — it must not have outgoing transitions.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `type` | Yes | — | `"resolve"` |
| `title` | Yes | — | Display name |
| `resolution_type` | **Yes** | `"success"` | One of: `success`, `failure`, `cancelled`, `escalated`, `transfer`, `ticket`, `manager_escalation`. Legacy values `other` (→ `failure`) and `transferred` (→ `transfer`) are auto-converted. **Step is flagged incomplete if blank.** |
| `description` | No | `""` | Rich text resolution description shown to the agent. If omitted, a default description is used based on `resolution_type`. |
| `notes_required` | No | `false` | When `true`, the agent must provide notes when resolving. |
| `survey_trigger` | No | `false` | When `true`, a satisfaction survey is triggered after resolution. |

### checkpoint *(not a step type — accepted and converted)*

Like `decision`, `checkpoint` is an accepted input dialect, converted to a
`message` step on import with a warning. `checkpoint_message` becomes the
message's `content`. Write a `message` step instead.


A mid-workflow checkpoint where the user can optionally mark the issue as resolved (completing the workflow early) or continue.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `type` | Yes | — | `"checkpoint"` |
| `title` | Yes | — | Display name |
| `checkpoint_message` | No | `""` | Message shown at the checkpoint |

### sub_flow

Calls another published TurboFlows workflow as a sub-routine. Variables are passed to the child workflow and results are merged back.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `type` | Yes | — | `"sub_flow"` |
| `title` | Yes | — | Display name |
| `target_workflow_id` | **Yes*** | — | Numeric ID of an existing **published** workflow in TurboFlows. Must not reference itself. |
| `target_workflow_title` | **Yes*** | — | Title of an existing **published** workflow. Resolved to `target_workflow_id` during import. |
| `variable_mapping` | No | `{}` | Hash mapping parent variable names to child variable names |

*\*One of `target_workflow_id` or `target_workflow_title` is required. If both are provided, `target_workflow_id` takes precedence and title resolution is skipped.*

**Title resolution rules:**
- The target workflow must already exist and be published before you import.
- Title matching is **case-insensitive** and **strips leading/trailing whitespace**.
- Only workflows with `status: 'published'` are considered (drafts are excluded).
- If **exactly one** published workflow matches the title, the `target_workflow_id` is set automatically and an informational warning is added.
- If **no** published workflows match, the step is flagged incomplete with an error. You can fix it in the editor after import.
- If **multiple** published workflows share the same title, the step is flagged incomplete with a warning listing all matches. You must resolve the ambiguity in the editor.
- The `target_workflow_title` field is transient — it is removed from the step data after resolution and is not persisted to the database.

### form

Collects structured data from the user via a set of form fields. Each field has a name, label, type, and optional required flag.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `type` | Yes | — | `"form"` |
| `title` | Yes | — | Display name |
| `instructions` | No | `""` | Rich text instructions displayed above the form fields |
| `options` | No | `[]` | Array of field definitions: `{ "name": "...", "label": "...", "field_type": "text", "required": true, "position": 0 }` |

**Field definition format:**

Each entry in the `options` array defines a form field:

| Property | Required | Description |
|----------|----------|-------------|
| `name` | Yes | Machine-readable field identifier (e.g., `"phone_number"`) |
| `label` | Yes | Human-readable label displayed to the user |
| `field_type` | No | Input type: `text`, `textarea`, `number`, `email`, `phone`, `select`, `checkbox` (default: `text`). Read from `Steps::Form::VALID_FIELD_TYPES`; earlier revisions listed a `date` type the builder has never offered |
| `required` | No | `true` to make the field mandatory (default: `false`) |
| `position` | No | Display order (default: array index) |

**Example:**

```json
{
  "id": "step-3",
  "type": "form",
  "title": "Collect Contact Information",
  "instructions": "Please gather the customer's contact details.",
  "options": [
    { "name": "full_name", "label": "Full Name", "field_type": "text", "required": true, "position": 0 },
    { "name": "email", "label": "Email Address", "field_type": "email", "required": true, "position": 1 },
    { "name": "phone", "label": "Phone Number", "field_type": "phone", "required": false, "position": 2 }
  ],
  "transitions": [
    { "target_uuid": "step-4" }
  ]
}
```

---

## Transitions

Transitions define the graph edges between steps. Every non-terminal step should have at least one transition.

Each transition object has:

| Field | Required | Description |
|-------|----------|-------------|
| `target_uuid` | Yes | The `id` of the target step |
| `condition` | No | A condition expression (e.g., `"issue_type == 'billing'"`). When present, this transition is only followed if the condition evaluates to true. |
| `label` | No | Display label for the edge in the visual editor |

**Routing rules:**
- Conditional transitions are evaluated in order; the first matching condition wins.
- If no conditional transition matches, the first unconditional transition (no `condition`) is followed as the default.
- `resolve` steps must have **no** transitions (they're terminal).
- If you omit transitions entirely from all steps, the importer generates a sequential chain (step 1 → step 2 → step 3 → ...). Decision steps use their `branches` and `else_path` fields to generate conditional transitions. This is convenient for simple workflows but explicit transitions are recommended for anything with branching.

---

## Auto-Generated Transitions

**There is no "linear mode".** Every workflow in TurboFlows is a graph; a
sequential flow is just a graph where each step has one transition to the next.
Omitting `transitions` is a convenience in the *file format* — the importer fills
them in — not a different kind of workflow. The importer still emits the warning
"Converted from linear format to Graph Mode", which is about the file, not the
result.

If your import file has **no `transitions` on any step**, the importer generates
them for you:

- **question, action, message, escalate, sub_flow, form**: A default transition to the next step in the array is added.
- **decision**: `branches` are converted to conditional transitions (resolving `path` values by step title), and `else_path` becomes an unconditional fallback transition.
- **checkpoint**: A default transition to the next step is added (unless it's the last step).
- **resolve**: Kept terminal with no transitions.

You can mix: if even one step has a `transitions` array, the importer treats the whole file as graph format and does NOT auto-generate transitions for other steps. In that case, make sure every non-terminal step has transitions.

---

## Format: JSON (Recommended)

JSON maps directly to the internal data model and supports all fields. Use this when you need full control.

```json
{
  "title": "Customer Support Flow",
  "description": "Handle customer inquiries with routing and resolution",
  "graph_mode": true,
  "start_node_uuid": "step-1",
  "steps": [
    {
      "id": "step-1",
      "type": "question",
      "title": "Get Customer Name",
      "question": "What is your name?",
      "answer_type": "text",
      "variable_name": "customer_name",
      "transitions": [
        { "target_uuid": "step-2" }
      ]
    },
    {
      "id": "step-2",
      "type": "question",
      "title": "Select Issue Type",
      "question": "What type of issue are you experiencing?",
      "answer_type": "multiple_choice",
      "variable_name": "issue_type",
      "options": [
        { "label": "Billing", "value": "billing" },
        { "label": "Technical", "value": "technical" },
        { "label": "General", "value": "general" }
      ],
      "transitions": [
        { "target_uuid": "step-3", "condition": "issue_type == 'billing'", "label": "Billing" },
        { "target_uuid": "step-4", "condition": "issue_type == 'technical'", "label": "Technical" },
        { "target_uuid": "step-5" }
      ]
    },
    {
      "id": "step-3",
      "type": "escalate",
      "title": "Route to Billing",
      "target_type": "department",
      "priority": "high",
      "reason": "Customer has a billing inquiry",
      "transitions": [
        { "target_uuid": "step-6" }
      ]
    },
    {
      "id": "step-4",
      "type": "action",
      "title": "Troubleshooting Steps",
      "instructions": "Walk the customer through basic troubleshooting:\n1. Restart the device\n2. Check internet connection\n3. Clear cache and cookies",
      "transitions": [
        { "target_uuid": "step-6" }
      ]
    },
    {
      "id": "step-5",
      "type": "message",
      "title": "General Assistance",
      "content": "Thank you for contacting us, {{customer_name}}. A representative will assist you shortly.",
      "transitions": [
        { "target_uuid": "step-6" }
      ]
    },
    {
      "id": "step-6",
      "type": "resolve",
      "title": "Complete Interaction",
      "resolution_type": "success",
      "resolution_notes": "Customer inquiry handled"
    }
  ]
}
```

### JSON without transitions

You can omit `transitions`, `graph_mode` and `start_node_uuid`. The importer chains the steps in order:

```json
{
  "title": "Simple Intake",
  "steps": [
    {
      "type": "question",
      "title": "Get Name",
      "question": "What is your name?",
      "answer_type": "text",
      "variable_name": "name"
    },
    {
      "type": "action",
      "title": "Welcome",
      "instructions": "Welcome {{name}}! Let me help you today."
    },
    {
      "type": "resolve",
      "title": "Done",
      "resolution_type": "success"
    }
  ]
}
```

### JSON with decision branches

Use `branches` and `else_path` on decision steps to create routing without writing explicit transitions:

```json
{
  "title": "Approval Flow",
  "steps": [
    {
      "type": "question",
      "title": "Request Amount",
      "question": "What is the request amount?",
      "answer_type": "text",
      "variable_name": "amount"
    },
    {
      "type": "decision",
      "title": "Check Amount",
      "branches": [
        { "condition": "amount == 'large'", "path": "Manager Approval" }
      ],
      "else_path": "Auto Approve"
    },
    {
      "type": "action",
      "title": "Manager Approval",
      "instructions": "Escalate to manager for approval of large amount."
    },
    {
      "type": "action",
      "title": "Auto Approve",
      "instructions": "Request auto-approved. Process the standard amount."
    },
    {
      "type": "resolve",
      "title": "Complete",
      "resolution_type": "success"
    }
  ]
}
```

The `path` values in branches must match step titles exactly (case-insensitive matching is attempted as a fallback).

---

## Format: CSV

CSV uses one row per step. The first row must be column headers.

### Required columns

| Column | Description |
|--------|-------------|
| `type` | Step type (see Step Types above). Also accepts `step_type`. |
| `title` | Step title. Also accepts `step_title`. |

### Optional columns

| Column | Used by | Description |
|--------|---------|-------------|
| `workflow_title` | All | Workflow title (only the first non-empty value is used) |
| `id` or `step_id` | All | Step ID. Auto-generated UUID if blank. |
| `description` or `step_description` | All | Step description |
| `question` or `question_text` | question | Question text |
| `answer_type` or `answer` | question | Answer type |
| `variable_name` or `variable` | question | Variable name for the answer |
| `options` | question, form | Comma-separated `Label:value` pairs or JSON array. For form steps, JSON array of field definitions. |
| `instructions` or `action` | action, form | Instruction text |
| `content` or `message` | message | Message content |
| `target_type` | escalate | Escalation target type |
| `target_id` | escalate | Target identifier (maps to `target_value`) |
| `priority` | escalate | Priority level |
| `reason` | escalate | Escalation notes (maps to `notes` rich text) |
| `resolution_type` | resolve | Resolution type |
| `resolution_notes` or `notes` | resolve | Resolution notes |
| `target_workflow_id` or `workflow_id` | sub_flow | Target workflow numeric ID |
| `target_workflow_title` or `workflow_title` | sub_flow | Target workflow title (resolved to ID during import) |
| `condition` | decision | Single condition (legacy) |
| `path` | decision | Single path (legacy) |
| `branches` | decision | Semicolon-separated `condition:path` pairs or JSON |
| `else_path` or `else` | decision | Fallback step title |
| `transitions` | All (except resolve) | Transition definitions (see below) |

### Transitions column syntax

The `transitions` column supports several formats:

| Format | Example | Meaning |
|--------|---------|---------|
| Simple target | `step-2` | Unconditional transition to step-2 |
| Multiple targets | `step-2;step-3` | Two transitions (semicolon separated) |
| With condition | `step-3:issue_type == 'billing';step-4` | Conditional + default |
| With label | `step-3->Billing Route` | Transition with a display label |
| Combined | `step-3:issue_type == 'billing'->Billing;step-4` | Condition + label + fallback |
| JSON array | `[{"target_uuid":"step-2"}]` | Full JSON transition objects |

### Options column syntax

| Format | Example |
|--------|---------|
| Label:value pairs | `Billing:billing,Technical:technical,Other:other` |
| Labels only | `Yes,No` (value auto-set to lowercase label) |
| JSON array | `[{"label":"Billing","value":"billing"}]` |

### Full CSV example

```csv
workflow_title,id,type,title,question,answer_type,variable_name,options,instructions,content,target_type,priority,reason,resolution_type,resolution_notes,transitions
Customer Support,step-1,question,Get Name,What is your name?,text,customer_name,,,,,,,,,step-2
,step-2,question,Issue Type,What type of issue?,multiple_choice,issue_type,"Billing:billing,Technical:technical,General:general",,,,,,,,step-3:issue_type == 'billing';step-4:issue_type == 'technical';step-5
,step-3,escalate,Route to Billing,,,,,,,department,high,Billing inquiry,,,step-6
,step-4,action,Troubleshooting,,,,,"Follow troubleshooting steps",,,,,,,step-6
,step-5,message,General Help,,,,,,"A representative will assist you shortly",,,,,,step-6
,step-6,resolve,Complete,,,,,,,,,,success,Issue resolved,
```

**Tip:** Leave `workflow_title` blank on rows after the first — only the first non-empty value is used.

---

## Format: YAML

YAML structure mirrors JSON but is more readable. Supports all the same fields.

```yaml
title: "Customer Support Flow"
description: "Handle customer inquiries with routing and resolution"
graph_mode: true
start_node_uuid: "step-1"
steps:
  - id: "step-1"
    type: question
    title: "Get Customer Name"
    question: "What is your name?"
    answer_type: text
    variable_name: customer_name
    transitions:
      - target_uuid: "step-2"

  - id: "step-2"
    type: question
    title: "Select Issue Type"
    question: "What type of issue are you experiencing?"
    answer_type: multiple_choice
    variable_name: issue_type
    options:
      - label: "Billing"
        value: "billing"
      - label: "Technical"
        value: "technical"
      - label: "General"
        value: "general"
    transitions:
      - target_uuid: "step-3"
        condition: "issue_type == 'billing'"
        label: "Billing"
      - target_uuid: "step-4"
        condition: "issue_type == 'technical'"
        label: "Technical"
      - target_uuid: "step-5"

  - id: "step-3"
    type: escalate
    title: "Route to Billing"
    target_type: department
    priority: high
    reason: "Customer billing inquiry"
    transitions:
      - target_uuid: "step-6"

  - id: "step-4"
    type: action
    title: "Troubleshooting"
    instructions: "Walk through troubleshooting steps:\n1. Restart device\n2. Check connection"
    transitions:
      - target_uuid: "step-6"

  - id: "step-5"
    type: message
    title: "General Help"
    content: "A representative will assist you shortly."
    transitions:
      - target_uuid: "step-6"

  - id: "step-6"
    type: resolve
    title: "Complete"
    resolution_type: success
    resolution_notes: "Issue resolved"
```

YAML supports omitted transitions and decision branches exactly as JSON does.

---

## Format: Markdown

Markdown is the most human-readable format. Steps are defined as `## Step N: Title` headings with `Key: Value` fields below each heading.

### Recognized fields

Fields are parsed from lines matching `Key: value` or `**Key**: value` (both work). All field names are case-insensitive.

| Field line | Maps to | Used by |
|------------|---------|---------|
| `Type:` | `type` | All |
| `Question:` | `question` | question |
| `Answer Type:` | `answer_type` | question |
| `Variable:` | `variable_name` | question |
| `Options:` or `Fields:` | `options` | question, form |
| `Instructions:` | `instructions` | action, form |
| `Content:` | `content` | message |
| `Target Type:` | `target_type` | escalate |
| `Target ID:` | `target_value` | escalate |
| `Priority:` | `priority` | escalate |
| `Reason:` | `notes` | escalate |
| `Resolution Type:` | `resolution_type` | resolve |
| `Resolution Notes:` | `resolution_notes` | resolve |
| `Target Workflow:` | `target_workflow_title` | sub_flow |
| `Target Workflow ID:` | `target_workflow_id` | sub_flow |
| `Condition:` | `branches[0].condition` | decision |
| `If true:` | `branches[0].path` | decision |
| `If false:` | `else_path` | decision |
| `Transitions:` | `transitions` | All |

### Transitions syntax in Markdown

The `Transitions:` line supports comma-separated targets with optional conditions in parentheses:

| Format | Example |
|--------|---------|
| Simple | `Transitions: Step 2` |
| Multiple | `Transitions: Step 2, Step 3` |
| With condition | `Transitions: Step 3 (if issue_type == 'billing'), Step 4 (if issue_type == 'technical'), Step 5` |

Step references in Markdown can use `Step N` (matched by position) or the full step title. The importer resolves these to the actual step IDs.

### Options syntax in Markdown

Same as CSV: `Label:value, Label:value` or plain `Label, Label` (auto-generates lowercase values).

### Full Markdown example

```markdown
# Customer Support Flow

Handle customer inquiries with routing and resolution.

## Step 1: Get Customer Name
Type: question
Question: What is your name?
Answer Type: text
Variable: customer_name
Transitions: Step 2

## Step 2: Select Issue Type
Type: question
Question: What type of issue are you experiencing?
Answer Type: multiple_choice
Variable: issue_type
Options: Billing:billing, Technical:technical, General:general
Transitions: Step 3 (if issue_type == 'billing'), Step 4 (if issue_type == 'technical'), Step 5

## Step 3: Route to Billing
Type: escalate
Target Type: department
Priority: high
Reason: Customer billing inquiry
Transitions: Step 6

## Step 4: Troubleshooting
Type: action
Instructions: Walk through troubleshooting steps
Transitions: Step 6

## Step 5: General Help
Type: message
Content: A representative will assist you shortly.
Transitions: Step 6

## Step 6: Complete
Type: resolve
Resolution Type: success
Resolution Notes: Issue resolved
```

### Markdown limitations

- **Sub-flow variable mapping:** Markdown supports `Target Workflow:` (title) and `Target Workflow ID:` (numeric ID), but does not support the `variable_mapping` hash. If you need variable mapping, use JSON or YAML instead and set it after import in the editor.
- **Form field definitions:** Markdown supports `Fields:` for simple `Label:type` pairs, but for complex form field definitions (with `required`, `position`, etc.), use JSON or YAML. You can refine field definitions in the editor after import.
- **Multi-line content:** Each field is parsed from a single line. For multi-line instructions or content, keep it on one line or use a different format.
- **Unrecognized lines** below a step heading are appended to the step's `description`.

---

## Incomplete Steps

The importer flags certain steps as incomplete rather than rejecting them. After import, you're redirected to the editor where incomplete steps are highlighted for you to fix.

A step is flagged incomplete when:

| Step type | Condition |
|-----------|-----------|
| `question` | `question` text is blank |
| `action` | `instructions` text is blank |
| `decision` | No transitions AND no branches with content |
| `resolve` | `resolution_type` is blank |
| `sub_flow` | `target_workflow_title` could not be resolved (no match or ambiguous match among published workflows) |

Incomplete steps skip model-level validation so they don't block the import. This includes sub_flow steps with unresolved titles — they skip the `validate_subflow_steps` check and can be fixed in the editor after import. All other step types (message, escalate, form, checkpoint) are never flagged incomplete by the parser.

---

## Validation Rules

After parsing, the workflow is validated by the model. These are the rules that can cause an import to fail:

### All steps
- `title` is required
- `type` must be one of: `question`, `action`, `sub_flow`, `message`, `escalate`, `resolve`, `form`
- Legacy types are auto-converted during import: `decision`/`simple_decision` → `question`, `checkpoint` → `message`

### question
- `question` text is required (unless flagged incomplete)

### decision
- If branches have a condition set, they must also have a path (and vice versa)
- Conditions must use valid syntax: `variable == 'value'`, `variable != 'value'`, or compound expressions with `&&`/`||`

### escalate
- `target_type` (if provided) must be one of: `team`, `queue`, `supervisor`, `channel`, `department`, `ticket`
- `priority` (if provided) must be one of: `low`, `medium`, `high`, `urgent`, `critical`

### resolve
- `resolution_type` (if provided) must be one of: `success`, `failure`, `cancelled`, `escalated`, `transfer`, `ticket`, `manager_escalation`. Legacy values are auto-converted: `other` → `failure`, `transferred` → `transfer`.
- Must not have outgoing transitions in graph mode

### form
- No required fields — form steps are never flagged incomplete
- `options` (field definitions) are preserved as-is; each field should have at minimum `name` and `label`

### sub_flow
- `target_workflow_id` must reference an existing, published workflow (unless step is flagged incomplete from title resolution)
- Cannot reference itself
- Circular sub-flow chains are rejected
- If `target_workflow_title` is provided instead of `target_workflow_id`, it is resolved during import (see the sub_flow step type section above for resolution rules)

### Graph structure
- All `target_uuid` values in transitions must reference existing step IDs
- The start node must exist

---

## Variable Interpolation

Step content fields (`instructions`, `content`, `question`, `notes`, `description`) support `{{variable_name}}` syntax. During simulation, these are replaced with values collected from earlier `question` steps (matched by `variable_name`).

Example: If step 1 collects `variable_name: "customer_name"`, later steps can use `"Hello, {{customer_name}}"`.

---

## Tips for Error-Free Imports

1. **Start with JSON or YAML** for complex workflows — they map closest to the internal model.
2. **Use CSV** for bulk step creation from spreadsheets, but watch your quoting (values with commas need double quotes).
3. **Use Markdown** for documentation-friendly workflows. Sub-flows are supported via `Target Workflow:` (title) or `Target Workflow ID:` (numeric ID), but `variable_mapping` must be set in the editor after import.
4. **Always end with a `resolve` step** — workflows without a terminal step will import but may not complete properly in simulations.
5. **Match branch paths to exact step titles** (case-insensitive fallback exists, but exact matches are safest).
6. **Test with a minimal workflow first** — import a 2-3 step workflow to verify your format, then expand.
7. **Use the new field values** for escalate and resolve steps (`department` not `team`, `medium` not `normal`, `transfer` not `transferred`) — the legacy values still work but the new ones match the current UI.
