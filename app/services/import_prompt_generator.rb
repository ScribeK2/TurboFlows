# The block a user copies into an external AI agent so it can write an import
# file. Generated from the same schema the agent validates against, so the two
# cannot drift — a prompt that describes a format the app no longer accepts is
# worse than no prompt.
#
# The worked example is a constant here rather than assembled, because it has to
# read like something a person would write. What keeps it honest is the test that
# runs it through StrictImportValidator: an example that does not import is worse
# than no example.
class ImportPromptGenerator
  EXAMPLE = <<~JSON.freeze
    {
      "schema_version": "1",
      "workflows": [
        {
          "title": "Internet Connection Troubleshooting",
          "description": "Basic connectivity checks for a customer whose internet is down.",
          "tags": ["support", "connectivity"],
          "steps": [
            {
              "id": "confirm-issue",
              "type": "question",
              "title": "Confirm the issue",
              "question": "Is the customer's internet completely down?",
              "answer_type": "yes_no",
              "variable_name": "fully_down",
              "transitions": [
                { "target_id": "restart-router", "condition": "fully_down == 'yes'" },
                { "target_id": "check-speed" }
              ]
            },
            {
              "id": "restart-router",
              "type": "action",
              "title": "Restart the router",
              "instructions": "<p>Ask the customer to unplug the router for <strong>30 seconds</strong>, then plug it back in and wait two minutes.</p>",
              "transitions": [{ "target_id": "did-it-work" }]
            },
            {
              "id": "did-it-work",
              "type": "question",
              "title": "Did that fix it?",
              "question": "Is the connection back?",
              "answer_type": "yes_no",
              "variable_name": "fixed",
              "transitions": [
                { "target_id": "resolved", "condition": "fixed == 'yes'" },
                { "target_id": "restart-router" }
              ]
            },
            {
              "id": "check-speed",
              "type": "message",
              "title": "Check the speed",
              "content": "<p>Run a speed test with the customer and note the result.</p>",
              "transitions": [{ "target_id": "hand-to-diagnostics" }]
            },
            {
              "id": "hand-to-diagnostics",
              "type": "sub_flow",
              "title": "Continue in slow-connection diagnostics",
              "target_workflow_title": "Slow Connection Diagnostics",
              "sub_flow_returns": false,
              "variable_mapping": { "fully_down": "line_was_dead" }
            },
            {
              "id": "resolved",
              "type": "resolve",
              "title": "Issue resolved",
              "resolution_type": "success"
            }
          ]
        },
        {
          "title": "Slow Connection Diagnostics",
          "description": "Follow-up when the connection works but is slower than it should be.",
          "tags": ["support", "connectivity"],
          "steps": [
            {
              "id": "wired-or-wifi",
              "type": "question",
              "title": "Wired or wireless?",
              "question": "Is the customer on Wi-Fi or plugged in with a cable?",
              "answer_type": "multiple_choice",
              "variable_name": "connection",
              "options": [
                { "label": "Wi-Fi", "value": "wifi" },
                { "label": "Wired", "value": "wired" }
              ],
              "transitions": [
                { "target_id": "move-closer", "condition": "connection == 'wifi'" },
                { "target_id": "book-engineer" }
              ]
            },
            {
              "id": "move-closer",
              "type": "action",
              "title": "Move closer to the router",
              "instructions": "<p>Ask the customer to stand next to the router and run the speed test again.</p>",
              "transitions": [{ "target_id": "book-engineer" }]
            },
            {
              "id": "book-engineer",
              "type": "resolve",
              "title": "Book an engineer",
              "resolution_type": "ticket",
              "description": "<p>Raise a ticket. Line reported fully dead: {{line_was_dead}}. Wi-Fi or wired: {{connection}}.</p>"
            }
          ]
        }
      ]
    }
  JSON

  def self.call = new.call

  def initialize
    @schema = ImportSchemaGenerator.call
  end

  def call
    [preamble, step_type_section, rules_section, example_section].join("\n")
  end

  private

  def preamble
    <<~MD
      # Writing a TurboFlows workflow file

      Produce a single JSON file in exactly this envelope:

      ```
      { "schema_version": "#{ImportSchemaGenerator::SCHEMA_VERSION}", "workflows": [ { ...a workflow... } ] }
      ```

      One file may carry a set of up to #{ImportSchemaGenerator::MAX_WORKFLOWS_PER_FILE} workflows, imported
      together. Split a domain into several when the parts are separately
      reusable — a diagnosis that routes into four procedures belongs as five
      workflows, not as one of seventy steps. The full JSON Schema is at
      `#{ImportSchemaGenerator::SCHEMA_URL}` — validate against it before handing the
      file over.

      A workflow needs a `title` and a `steps` array. It may also carry
      `description`, `tags` (plain names), `groups` (see below), `folder`, and
      `start_step_id` (defaults to the first step).
    MD
  end

  def step_type_section
    rows = Workflow::VALID_STEP_TYPES.map do |type|
      required = branch(type)["required"] - %w[id type title transitions]
      optional = branch(type)["properties"].keys - branch(type)["required"] -
                 %w[help_text reference_url]
      "| `#{type}` | #{fields(required)} | #{fields(optional)} |"
    end

    <<~MD
      ## Step types

      Every step needs `id`, `type`, `title`, and at least one transition. Two
      kinds of step end the workflow instead and take none: `resolve`, and a
      `sub_flow` with `sub_flow_returns: false` (see Handoffs below).

      | type | also required | optional |
      |---|---|---|
      #{rows.join("\n")}

      Every step also accepts `help_text` and `reference_url`.
    MD
  end

  def rules_section
    <<~MD
      ## Rules that are easy to get wrong

      **Ids.** Every step needs an `id` you choose: 1-64 characters of letters,
      digits, hyphen or underscore. Readable slugs like `verify-account` beat
      UUIDs — transitions reference them, so you can check your own work.

      **Transitions are explicit.** Every step needs at least one, and nothing is
      inferred. The exceptions are the two steps that end a workflow: a `resolve`
      step and a handed-off `sub_flow` must have none at all. `target_id` names
      another step's `id` in the same workflow. A transition never crosses from
      one workflow to another — that is what `sub_flow` is for.

      **Loops are allowed** — "didn't work, try again" is a normal shape. What is
      refused is a loop with no way out: from every step, some path must still be
      able to reach a `resolve` step.

      **Workflows may hand off to each other freely, including in a circle.**
      "Billing sends them to Domains, Domains sends them back" is a normal
      call-centre shape, and a handoff ends the current workflow rather than
      nesting inside it. A workflow that only hands off — no `resolve` of its
      own — is fine too, as long as the chain of handoffs it starts eventually
      reaches one. What is refused is the chain that never does: if the only way
      out of a workflow is a handoff, and the only way out of that one is a
      handoff back, nobody can ever finish the call.

      **A returning sub-flow may not cycle.** When `sub_flow_returns` is true
      (the default) the caller waits for the target, so A calling B calling A
      would nest forever. Those chains are also capped at
      #{SubflowValidator::MAX_DEPTH} levels deep.

      **Rich text is HTML, not Markdown.** `instructions`, `content`, `notes` and
      `description` are stored as HTML — use `<p>`, `<strong>`, `<em>`,
      `<ul>/<ol>/<li>`, `<a href>`. Markdown is not converted and will render
      literally, asterisks and all.

      **Conditions are one comparison.** No `&&` or `||`, string values quoted,
      numbers whole and positive. Supported forms:
      #{StrictImportValidator::CONDITION_FORMS.map { |f| "`#{f}`" }.join(', ')}.
      A quote inside a value is escaped as `\\'` — `choice == 'Don\\'t know'`.
      A condition outside these silently never fires, so the import refuses it.

      **Variables.** `variable_name` on a question stores the answer; refer to it
      in a condition, or interpolate it into text as `{{variable_name}}`.

      **Groups** are named by path from the root, e.g.
      `"groups": ["Support / Tier 2"]`, or by the group's own name when that
      name is unique. The group must already exist and you must have access
      to it — assignment to a parent covers its children. Use
      `"groups": [["Support", "Tier 2"]]` if a name contains a slash; a
      flat `["Support", "Tier 2"]` is two groups, not one path.

      **Form fields of type `select` must list their choices.** Put them in
      `select_options` on the field, as `{"label": ..., "value": ...}` — the same
      shape a question's `options` uses. A select with no `select_options`
      renders as an empty dropdown the agent cannot answer, so do not encode the
      choices in the label text.

      **Handoffs.** A `sub_flow` normally *calls* its target: the sub-flow runs,
      then the agent comes back to this workflow and follows this step's
      transitions. Set `sub_flow_returns: false` and it *hands over* instead —
      the run moves to the target and never comes back, so the step ends this
      workflow. A handed-off step therefore takes no transitions and needs no
      `resolve` after it. Use it to point an agent at the next script rather than
      dead-ending them; use the default when you need the answers back.

      **Sub-flows** name their target by `target_workflow_title`. That title may
      be another workflow **in this same file** — which is the reason to put a
      linked set in one file, since it then needs nothing to exist beforehand.
      Otherwise it must match a workflow that already exists and is published.
      Two workflows in one file cannot share a title, because that is how a
      target is matched.

      **A sub-flow inherits every variable collected so far**, under the same
      name, so you usually need nothing to pass data down. `variable_mapping`
      *renames* one for the sub-flow, written
      `{"name_here": "name_inside_the_sub_flow"}` — the key is this workflow's
      name for the value, the value is the sub-flow's. Reach for it only when
      the sub-flow is written against a different name, which is the normal case
      for a sub-flow shared by several callers that each collect the same thing
      under a name of their own.

      **And it hands them back.** When a sub-flow returns, every variable it
      collected is available to the caller under the same name, so the step
      after it may branch on the sub-flow's answers — run a shared
      "Verify identity" workflow, then branch on its `verified`. A handoff
      (`sub_flow_returns: false`) never returns, so nothing comes back from one.
    MD
  end

  def example_section
    <<~MD
      ## A complete example

      Two workflows in one file. Note three things: the retry loop, where
      `did-it-work` sends the agent back to `restart-router` and the flow is
      still valid because a `resolve` stays reachable from every step; the
      handoff, where `hand-to-diagnostics` ends the first workflow by moving the
      run to the second rather than returning to it; and that the second workflow
      is named by title from inside the same file, so neither has to exist
      beforehand. The `variable_mapping` on the handoff is a rename, not a
      transfer: `fully_down` would have crossed anyway, but the second workflow
      is written against `line_was_dead`, so the mapping is what makes
      `{{line_was_dead}}` resolve.

      ```json
      #{EXAMPLE.strip}
      ```
    MD
  end

  def branch(type)
    @schema["$defs"]["step"]["oneOf"].find { |b| b["properties"]["type"]["const"] == type }
  end

  def fields(names)
    names.empty? ? "—" : names.map { |n| "`#{n}`" }.join(", ")
  end
end
