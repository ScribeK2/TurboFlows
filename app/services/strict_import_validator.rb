# Validates a strict-dialect import file without writing anything.
#
# Every check appends to one errors array, so a failing file comes back with all
# of its problems at once — an agent can fix ten errors in one pass but cannot
# see a silent drop. The codes are a published contract: once one ships, it does
# not get renamed.
#
# Resolution is deliberately separate from application: an unknown group or an
# unresolvable sub-flow target is a validation result, not an exception thrown
# partway through a write.
class StrictImportValidator
  # `workflows_data` and `placements` are parallel arrays, one entry per workflow
  # in the file, in file order. They were singular until the envelope accepted
  # more than one workflow; the pair has to stay index-aligned because the
  # importer applies placements[i] to the workflow it built from
  # workflows_data[i].
  Report = Data.define(:errors, :warnings, :workflows_data, :placements) do
    def valid? = errors.empty?

    # The overwhelmingly common case is still one workflow, and the report view
    # and several tests only ever want that one. Convenience, not a second
    # contract: anything that writes must use the arrays.
    def workflow_data = workflows_data&.first
    def placement = placements&.first
    def multiple? = workflows_data.to_a.size > 1
  end

  # The only condition forms ConditionEvaluator accepts. Quoted back to the agent
  # in the error, because there is nowhere else it could learn them.
  CONDITION_FORMS = [
    "var == 'value'", "var != 'value'", "var > 10", "var >= 10", "var < 10", "var <= 10"
  ].freeze

  CONDITION_VARIABLE = /\A\s*(\w+)\s*(?:>=|<=|==|!=|>|<)/

  # id, type and transitions have their own codes, so they are reported by their
  # own checks rather than as a generic missing field.
  SELF_REPORTING_FIELDS = %w[id type transitions].freeze

  def self.strict?(content)
    parsed = JSON.parse(content.to_s)
    parsed.is_a?(Hash) && parsed.key?("schema_version")
  rescue JSON::ParserError
    false
  end

  def initialize(user:, content:)
    @user = user
    @content = content
    @errors = []
    @warnings = []
  end

  def validate
    document = parse_document
    return report if document.nil?

    check_schema_version(document)
    return report if @errors.any?

    workflows = extract_workflows(document)
    return report if workflows.nil?

    # Titles first: an in-bundle sub_flow target is resolved by title, so two
    # workflows sharing one in the same file makes every reference to it
    # ambiguous. Checked before anything reads the titles.
    validate_bundle_titles(workflows)

    # Placement is checked before the structural gate because it does not depend
    # on the steps at all. A file with a bad step AND a bad group would otherwise
    # cost two round trips to learn about the group — and telling an agent
    # everything at once is the point of this path.
    placements = workflows.map.with_index { |workflow, i| validate_placement(workflow, path_for(i)) }

    # The passes below DO depend on sound structure: the graph validator cannot
    # traverse dangling targets, and the semantic checks read fields that a
    # malformed step may not have. So structure gates them.
    workflows.each_with_index { |workflow, i| validate_structure(workflow, path_for(i)) }
    return report(placements:) if @errors.any?

    normalized = workflows.map { |workflow| normalize(workflow) }

    # What each workflow receives from its callers, before any of them is checked
    # in isolation. Computed across the whole bundle because that is the only
    # place a caller is visible — see #inherited_variables.
    inherited = inherited_variables(normalized)

    normalized.each_with_index do |workflow, i|
      validate_graph(workflow, path_for(i))
      validate_semantics(workflow, path_for(i), inherited[i])
    end
    resolve_sub_flow_targets(normalized)

    report(workflows_data: normalized, placements:)
  end

  private

  def parse_document
    document = JSON.parse(@content.to_s)

    unless document.is_a?(Hash)
      add_error("", "envelope_invalid", document.class.name,
                "The file must contain a JSON object at the top level.")
      return nil
    end

    document
  rescue JSON::ParserError => e
    add_error("", "malformed_json", nil, "The file is not valid JSON: #{e.message}")
    nil
  end

  def check_schema_version(document)
    version = document["schema_version"]
    return if version == ImportSchemaGenerator::SCHEMA_VERSION

    add_error("schema_version", "unsupported_schema_version", version,
              "schema_version #{version.inspect} is not supported.",
              expected: [ImportSchemaGenerator::SCHEMA_VERSION])
  end

  # The JSON path for one workflow in the file. Every per-workflow check takes
  # this rather than hardcoding `workflows[0]`, which is what every path in here
  # did while the envelope only ever held one.
  def path_for(index) = "workflows[#{index}]"

  def extract_workflows(document)
    workflows = document["workflows"]

    unless workflows.is_a?(Array)
      return add_error("workflows", "envelope_invalid", workflows,
                       "The file must carry a 'workflows' array.")
    end

    if workflows.empty?
      return add_error("workflows", "envelope_invalid", 0,
                       "The file carries no workflows.")
    end

    if workflows.length > ImportSchemaGenerator::MAX_WORKFLOWS_PER_FILE
      return add_error("workflows", "envelope_invalid", workflows.length,
                       "A file carries at most " \
                       "#{ImportSchemaGenerator::MAX_WORKFLOWS_PER_FILE} workflows; " \
                       "this one has #{workflows.length}.")
    end

    malformed = workflows.each_with_index.reject { |workflow, _| workflow.is_a?(Hash) }
    malformed.each do |workflow, index|
      add_error(path_for(index), "envelope_invalid", workflow.class.name,
                "Each entry in 'workflows' must be an object.")
    end

    malformed.any? ? nil : workflows
  end

  # Two workflows in one file cannot share a title.
  #
  # Not a tidiness rule: a sub_flow step names its target by title, and inside a
  # bundle that title is resolved against the file itself, so a duplicate makes
  # every reference to it ambiguous with no way for the agent to disambiguate.
  # Titles that merely collide with an existing published workflow are fine —
  # the bundle wins, see #resolve_sub_flow_targets.
  def validate_bundle_titles(workflows)
    seen = {}

    workflows.each_with_index do |workflow, index|
      title = workflow["title"].to_s.strip
      next if title.blank?

      key = title.downcase
      if seen.key?(key)
        add_error("#{path_for(index)}.title", "duplicate_workflow_title", title,
                  "Two workflows in this file are titled #{title.inspect} " \
                  "(also at #{path_for(seen[key])}). A sub_flow target inside a file is " \
                  "resolved by title, so the two cannot be told apart.")
      else
        seen[key] = index
      end
    end
  end

  # --- external references -----------------------------------------------------

  # Placement is per workflow, never bundle-wide: WorkflowPlacement already
  # resolves one workflow's groups, folder and tags, and a bundle-level default
  # with per-workflow overrides is a configuration surface nobody has asked for.
  def validate_placement(workflow, path)
    placement = WorkflowPlacement.new(
      user: @user,
      groups: workflow["groups"] || [],
      folder: workflow["folder"],
      tags: workflow["tags"] || []
    )

    resolved = placement.resolve
    resolved.errors.each do |error|
      add_error("#{path}.#{error[:path]}", error[:code], error[:value], error[:message])
    end
    resolved.warnings.each do |warning|
      add_warning("#{path}.#{warning[:path]}", warning[:code], warning[:value], warning[:message])
    end

    placement
  end

  # The lenient path does this in BaseParser#resolve_subflow_titles. The strict
  # path never runs a parser, so without this a sub_flow step would import
  # pointing at nothing — silently, which is the whole class of failure this
  # dialect exists to remove. Same lookup as the lenient resolver (published
  # workflows, case-insensitive) so both paths resolve a title identically; the
  # difference is severity, since the lenient one only marks the step incomplete.
  #
  # A draft match gets its own code. Imports land as drafts, so "import A, then
  # import B whose sub_flow targets A" fails where it used to work, and telling
  # the user A does not exist would send them off to re-author a workflow they
  # already have.
  # A target may now name a workflow defined in this same file, which is the
  # whole point of accepting more than one: the chicken-and-egg that made a
  # linked set unimportable was that a target had to exist AND be published
  # first.
  #
  # An in-bundle match is left as `target_workflow_title` and NOT resolved to an
  # id, because no id exists yet — nothing has been written. WorkflowImporter
  # creates every workflow in the bundle before it builds any steps, and
  # resolves the remaining titles against what it just created.
  #
  # The bundle wins over a published workflow of the same title. The file in
  # front of you is the more specific statement of intent, and the alternative —
  # refusing as ambiguous — would make a title collision with any existing
  # workflow break a self-contained bundle.
  def resolve_sub_flow_targets(workflows)
    bundle_titles = workflows.filter_map { |w| w["title"].to_s.strip.downcase.presence }.to_set

    workflows.each_with_index do |workflow, w_index|
      Array(workflow["steps"]).each_with_index do |step, index|
        next unless step["type"] == "sub_flow"

        title = step["target_workflow_title"].to_s.strip
        path = "#{path_for(w_index)}.steps[#{index}].target_workflow_title"

        if bundle_titles.include?(title.downcase)
          # The bundle wins, deliberately — but say so. Silently rebinding every
          # sub_flow from an existing published workflow to a new draft of the
          # same name, with the report page saying nothing, is the wrong-result-
          # no-error shape this dialect exists to remove.
          if visible_published_workflows(title).exists?
            add_warning(path, "shadowed_published_target", title,
                        "A published workflow is also titled #{title.inspect}. This sub-flow " \
                        "will run the copy defined in this file, not the published one.")
          end
          next
        end

        published = visible_published_workflows(title)

        if published.one?
          step["target_workflow_id"] = published.first.id
          step.delete("target_workflow_title")
        elsif published.many?
          add_error(path, "ambiguous_sub_flow_target", title,
                    "#{published.count} published workflows are titled #{title.inspect} " \
                    "(#{published.map { |w| "##{w.id}" }.join(', ')}). Rename one, or import " \
                    "this workflow without the sub-flow step and set the target in the builder.")
        else
          report_missing_sub_flow_target(title, path)
        end
      end
    end
  end

  # Scoped to what this user may actually see, not every workflow in the install.
  # An unscoped lookup would let an importing editor bind a sub-flow to a workflow
  # they have no access to, and would confirm the existence and id of workflows
  # they cannot otherwise reach. Workflow.visible_to is already published-only.
  def visible_published_workflows(title)
    Workflow.visible_to(@user).where("LOWER(title) = LOWER(?)", title)
  end

  def report_missing_sub_flow_target(title, path)
    # Only the user's OWN drafts. The helpful case is "I imported A a moment ago
    # and it is still a draft"; anyone else's draft is none of their business, and
    # saying it exists would leak a private title back to whoever wrote the file.
    if @user.workflows.where.not(status: "published").exists?(["LOWER(title) = LOWER(?)", title])
      add_error(path, "sub_flow_target_not_published", title,
                "A workflow titled #{title.inspect} exists but is still a draft. Publish it " \
                "first — a sub-flow can only run a published workflow.")
    else
      add_error(path, "unknown_sub_flow_target", title,
                "No published workflow is titled #{title.inspect}. A sub-flow target must " \
                "either already exist and be published, or be defined as another workflow " \
                "in this same file.")
    end
  end

  # --- semantics ---------------------------------------------------------------

  # The checks that catch what a competent agent still gets wrong. ConditionEvaluator
  # accepts six regexes and nothing else — no && or ||, string values quoted,
  # numeric comparisons matching \d+ so "> 3.5" and "> -1" do not parse — and
  # #evaluate returns false for anything unparseable rather than raising. An
  # invalid condition is therefore a branch that silently never fires on a live
  # call, which is why it is an error rather than a warning.
  #
  # The variable and option checks are warnings: a variable can legitimately
  # arrive from scenario inputs rather than an upstream question, so treating
  # either as an error would reject valid files.
  def validate_semantics(workflow, workflow_path, inherited = Set.new)
    steps = workflow["steps"]
    defined = defined_variables(steps) | inherited
    options = options_by_variable(steps)

    steps.each_with_index do |step, index|
      path = "#{workflow_path}.steps[#{index}]"
      validate_interpolations(step, path, defined)

      Array(step["transitions"]).each_with_index do |transition, t_index|
        condition = transition["condition"]
        next if condition.blank?

        validate_condition(condition, "#{path}.transitions[#{t_index}].condition",
                           defined, options)
      end
    end
  end

  def validate_condition(condition, path, defined, options)
    unless supported_condition?(condition)
      return add_error(path, "invalid_condition_syntax", condition,
                       "#{condition.inspect} is not a supported condition. One comparison " \
                       "only — no && or ||, string values quoted, numbers whole and positive; " \
                       "a quote inside a value is escaped as \\'.",
                       expected: CONDITION_FORMS)
    end

    name = condition[CONDITION_VARIABLE, 1]
    return if name.nil?

    # Matched the way ConditionEvaluator reads a name, not the way it is
    # spelled: case-insensitively, with the legacy name "answer" always known.
    # Not "this branch will not fire": against an unset variable `!=`, `<` and
    # `<=` ALWAYS fire (nil means true; numbers compare against 0).
    unless WorkflowVariableNames.condition_matcher(defined).call(name)
      return add_warning(path, "undefined_variable", name,
                         "No step in this workflow sets #{name}, so this branch cannot route " \
                         "on it unless the scenario supplies it.")
    end

    check_option_value(condition, path, name, options)
  end

  # Reads the value through the same tokenizer the runner uses, rather than a
  # second regex of its own — that second regex is the defect this replaced:
  # it could not read an ESCAPED quote or backslash, so `choice == 'Don\'t
  # know'` extracted "Don\" and warned against a real option. A well-formed
  # comparison has two readings (see ConditionEvaluator's own comment), and the
  # runner takes an answer matching either, so this checks both — an
  # old-style `path == 'C:\temp'` against the option `C:\temp` must not warn.
  # The warning quotes `literal_value`, the text as the author wrote it, not
  # the unescaped reading.
  #
  # Only ==/!= reach here with an actual value to check — a numeric comparison
  # (>, <, >=, <=) never sets parsed[:operator] to either, so it never reaches
  # this far. And ==/!= only reach here at all once #supported_condition? has
  # already accepted the condition, which — unlike a numeric comparison —
  # requires a QUOTED value for ==/!=; an unquoted `plan == 9` is refused as
  # invalid_condition_syntax before this method is ever called, exactly as the
  # old regex (which only matched `==`/`!=` followed by a quote) never saw one
  # either. Nothing here special-cases that shape; there is nothing to reach.
  #
  # #options_by_variable already coerces every option value to a String
  # (`.to_s`), so this compares like with like even when the source file wrote
  # a numeric-looking option as a bare JSON number rather than the string the
  # published schema asks for — a File difference the app doesn't otherwise
  # enforce, not a reason to stop checking every numeric-looking value, which
  # would silently let `plan == '9'` through against options declared as
  # ["3", "4"].
  def check_option_value(condition, path, name, options)
    parsed = ConditionEvaluator.new(condition).parse
    return unless parsed && %w[== !=].include?(parsed[:operator])

    values = options[name]
    return if values.nil? || values.include?(parsed[:value]) || values.include?(parsed[:literal_value])

    add_warning(path, "unmatched_option_value", parsed[:literal_value],
                "#{name} never takes the value #{parsed[:literal_value].inspect}. Its question " \
                "offers: #{values.join(', ')}.")
  end

  def supported_condition?(condition)
    ConditionEvaluator.complete?(condition)
  end

  # What a workflow's own steps put in the bag. The list of writers lives in
  # WorkflowVariableNames, shared with the builder's health check; this only
  # says how a parsed step reads. It used to be `variable_name` alone, which
  # warned on every condition naming a step title or a Form field — names the
  # runtime really does write. `output_fields` is absent on purpose: the dialect
  # refuses the field (ImportSchemaGenerator::EXCLUDED_FIELDS).
  def defined_variables(steps)
    WorkflowVariableNames.written_by(steps.filter_map { |step| variable_row(step) })
  end

  def variable_row(step)
    return unless step.is_a?(Hash)

    WorkflowVariableNames::Row.new(title: step["title"], variable_name: step["variable_name"],
                                   form_fields: (step["options"] if step["type"] == "form"),
                                   output_fields: nil, mapping: step["variable_mapping"])
  end

  # What each workflow in the bundle receives from whoever calls it.
  #
  # A sub-flow does not start empty. ScenarioStepProcessor seeds the child with
  # `(@scenario.results || {}).dup` — the caller's whole bag — and only then
  # applies `variable_mapping`, which therefore *renames* rather than selects.
  # So a variable a caller set is genuinely defined inside its sub-flow, and
  # checking each workflow in isolation reported a false `undefined_variable` on
  # every correct bundle that passes data down. The schema and the agent prompt
  # both claimed the opposite ("only mapped variables are seeded") until this was
  # spiked against a real run.
  #
  # Transitive, because inheritance is: in A -> B -> C, C receives what B had,
  # and B had everything A had. A one-hop version would still be wrong for the
  # very shape the prompt asks agents to write when it tells them to split a
  # domain into several workflows.
  #
  # Iterative to a fixed point rather than recursive, so a cyclic bundle
  # terminates here instead of relying on SubflowValidator, which refuses cycles
  # only later, at import. Sets grow monotonically and are bounded by the names
  # in the file, so the loop always settles; the bundle is capped at
  # ImportSchemaGenerator::MAX_WORKFLOWS_PER_FILE, so the cost is nil.
  #
  # Only in-bundle edges are followed. An out-of-bundle target is a published
  # workflow that is not being validated here, so nothing it inherits matters.
  def inherited_variables(workflows)
    own = workflows.map { |workflow| defined_variables(Array(workflow["steps"])) }
    index_by_title = {}
    workflows.each_with_index do |workflow, i|
      index_by_title[workflow["title"].to_s.strip.downcase] = i
    end

    inherited = Array.new(workflows.size) { Set.new }

    loop do
      changed = false

      workflows.each_with_index do |workflow, caller_index|
        Array(workflow["steps"]).each do |step|
          next unless step["type"] == "sub_flow"

          target = index_by_title[step["target_workflow_title"].to_s.strip.downcase]
          next if target.nil?

          incoming = own[caller_index] | inherited[caller_index] | renamed_variables(step)
          before = inherited[target].size
          inherited[target] |= incoming
          changed ||= inherited[target].size != before

          # And back up. Scenario#process_subflow_completion merges every
          # non-internal child key into the parent, so a caller legitimately
          # tests a variable only its child sets. A handoff
          # (sub_flow_returns: false) is a tail call: nothing comes back.
          next if step["sub_flow_returns"] == false

          before = inherited[caller_index].size
          inherited[caller_index] |= own[target] | inherited[target]
          changed ||= inherited[caller_index].size != before
        end
      end

      break unless changed
    end

    inherited
  end

  # The names a mapping creates inside the sub-flow. The hash is written
  # {name_out_here => name_in_there} (ScenarioStepProcessor#process_subflow_step),
  # so it is the values that exist on the far side.
  def renamed_variables(step)
    mapping = step["variable_mapping"]
    return Set.new unless mapping.is_a?(Hash)

    mapping.values.filter_map { |name| name.to_s.presence }.to_set
  end

  # #check_option_value is the only reader of this map (grep confirms it), so
  # coercing here is safe: nothing else sees the un-coerced values. A
  # condition's value is always a String — ConditionEvaluator#parse produces
  # one whichever reading is used — so an option value is coerced to a String
  # too. Without this, an option written as a bare JSON number (the published
  # schema asks for a string, but nothing here enforces that) would never `==`
  # the parsed String, a false "unmatched" warning from JSON's number/string
  # split rather than a real mismatch; WITH it, a genuinely unmatched
  # numeric-looking value — `plan == '9'` against options ["3", "4"] — still
  # warns, exactly as it did before ConditionEvaluator#parse replaced the old
  # regex here.
  def options_by_variable(steps)
    steps.each_with_object({}) do |step, map|
      next unless step["type"] == "question" && step["variable_name"].present?
      next unless step["options"].is_a?(Array)

      values = step["options"].filter_map { |o| o.is_a?(Hash) ? o["value"] : nil }.map(&:to_s)
      map[step["variable_name"]] = values if values.any?
    end
  end

  def validate_interpolations(step, path, defined)
    step.each do |field, value|
      next unless value.is_a?(String)

      value.scan(VariableInterpolator::VARIABLE_PATTERN).flatten.uniq.each do |name|
        next if defined.include?(name)

        add_warning("#{path}.#{field}", "undefined_variable", name,
                    "{{#{name}}} is not set by any step in this workflow. The agent will " \
                    "see the braces as written unless the scenario supplies it.")
      end
    end
  end

  # --- graph -----------------------------------------------------------------

  # The same validator WorkflowPublisher#validate_ar_graph! runs, at the same
  # severity. The point of the dry run is that it says exactly what publish would
  # say — a validator that blesses files the app later rejects is worse than no
  # validator at all. Since the escapability rule replaced the acyclic check that
  # includes accepting loops: what GraphValidator refuses is a step with no path
  # to a Resolve, not a cycle as such.
  #
  # Runs on the normalized workflow, because GraphValidator reads target_uuid.
  def validate_graph(workflow, workflow_path)
    steps = workflow["steps"]
    keyed = steps.index_by { |step| step["id"] }
    start_id = workflow["start_step_id"] || steps.first["id"]

    validator = GraphValidator.new(keyed, start_id)
    return if validator.valid?

    validator.findings.each do |finding|
      add_error(workflow_path, "graph_invalid", finding.code.to_s, finding.message)
    end
  end

  # --- structure -------------------------------------------------------------

  def validate_structure(workflow, workflow_path)
    validate_workflow_fields(workflow, workflow_path)
    validate_workflow_title(workflow, workflow_path)

    steps = workflow["steps"]
    unless steps.is_a?(Array) && steps.any?
      return add_error("#{workflow_path}.steps", "envelope_invalid", nil,
                       "A workflow needs at least one step.")
    end

    seen_ids = {}

    steps.each_with_index do |step, index|
      path = "#{workflow_path}.steps[#{index}]"
      unless step.is_a?(Hash)
        next add_error(path, "envelope_invalid", step.class.name,
                       "Each step must be an object.")
      end

      validate_step_id(step, path, seen_ids, index)
      type = validate_step_type(step, path)
      next if type.nil?

      validate_fields(step, type, path)
      validate_required(step, type, path)
      validate_enums(step, path)
      validate_form_fields(step, type, path)
      validate_step_transitions(step, type, path)
    end

    validate_transition_targets(steps, seen_ids.keys, workflow_path)
  end

  # Workflow validates title presence and a 255-character maximum. Without this
  # the dry run would report "valid" and the commit would then fail on an AR
  # validation, breaking the promise the report rests on: it says exactly what
  # committing would say.
  # The keys a workflow object may carry, from the same schema branch the steps
  # are checked against.
  #
  # Nothing checked the workflow envelope at all: `validate_fields` runs per
  # step, so a misspelled workflow-level key was silently ignored. An agent
  # writing `start_step` instead of `start_step_id` got no error and a workflow
  # that quietly started at its first step — a silent drop, in the dialect whose
  # whole purpose is that a file cannot fail quietly.
  def validate_workflow_fields(workflow, workflow_path)
    allowed = workflow_schema_properties.keys

    workflow.each_key do |key|
      next if allowed.include?(key)

      add_error("#{workflow_path}.#{key}", "unknown_field", workflow[key],
                "#{key} is not a field on a workflow.", expected: allowed.sort)
    end
  end

  def validate_workflow_title(workflow, workflow_path)
    title = workflow["title"]

    # Type-checked, not just coerced. A JSON `true` passes `.to_s` as "true" and
    # every downstream comparison uses that, but ActiveModel casts the column to
    # "t" on save — so an in-bundle sub_flow target matched at validation time
    # and bound to nothing at import time, with the import reporting success.
    # Two titles that differ before the cast and collide after it also defeated
    # the duplicate-title check that in-bundle resolution depends on.
    if !title.nil? && !title.is_a?(String)
      return add_error("#{workflow_path}.title", "invalid_workflow_title", title,
                       "A workflow title must be a string, not #{title.class.name.downcase}.")
    end

    if title.blank?
      add_error("#{workflow_path}.title", "invalid_workflow_title", title,
                "A workflow needs a title.")
    elsif title.to_s.length > 255
      add_error("#{workflow_path}.title", "invalid_workflow_title", title.to_s.truncate(60),
                "A workflow title is at most 255 characters; this one is #{title.to_s.length}.")
    end
  end

  def validate_step_id(step, path, seen_ids, index)
    id = step["id"]

    if id.blank?
      return add_error("#{path}.id", "missing_step_id", nil,
                       "Every step needs an id; transitions reference it.")
    end

    unless id.to_s.match?(step_id_pattern)
      return add_error("#{path}.id", "invalid_step_id", id,
                       "Step ids must be 1-64 characters of letters, digits, hyphen " \
                       "or underscore, starting with a letter or digit.")
    end

    if seen_ids.key?(id)
      add_error("#{path}.id", "duplicate_step_id", id,
                "Step id #{id.inspect} is already used by step #{seen_ids[id]} in this file.")
    else
      seen_ids[id] = index
    end
  end

  def validate_step_type(step, path)
    type = step["type"]
    return type if Workflow::VALID_STEP_TYPES.include?(type)

    add_error("#{path}.type", "unknown_step_type", type,
              "#{type.inspect} is not a step type.",
              expected: Workflow::VALID_STEP_TYPES)
  end

  def validate_fields(step, type, path)
    allowed = allowed_keys_for(type)

    step.each_key do |key|
      next if allowed.include?(key)

      if excluded_field_names.include?(key)
        add_error("#{path}.#{key}", "excluded_field", step[key],
                  "#{key} cannot be edited anywhere in the TurboFlows builder, so this " \
                  "dialect does not accept it — nobody could correct it afterwards.")
      else
        add_error("#{path}.#{key}", "unknown_field", step[key],
                  "#{key} is not a field on a #{type} step.", expected: allowed.sort)
      end
    end
  end

  def validate_required(step, type, path)
    schema_branch(type)["required"].each do |field|
      next if SELF_REPORTING_FIELDS.include?(field)
      next if step[field].present?

      add_error("#{path}.#{field}", "missing_required_field", nil,
                "A #{type} step needs #{field}.")
    end
  end

  def validate_enums(step, path)
    ImportSchemaGenerator::ENUMS.each do |field, values|
      value = step[field.to_s]
      next if value.blank?
      next if values.call.include?(value)

      add_error("#{path}.#{field}", "invalid_enum_value", value,
                "#{value.inspect} is not a valid #{field}.", expected: values.call)
    end
  end

  # A select field has to say what it offers.
  #
  # Nothing could supply `select_options` before 2026-09-04 — the permit list
  # dropped it, the schema rejected it as an additional property, and the
  # builder had no control for it — so a select field always rendered an empty
  # dropdown. Now that the key exists, an omission is a real authoring mistake
  # and it produces a step the agent cannot answer, which is an error rather
  # than a warning for the same reason an unparseable condition is.
  def validate_form_fields(step, type, path)
    return unless type == "form"
    return unless step["options"].is_a?(Array)

    step["options"].each_with_index do |field, index|
      next unless field.is_a?(Hash)

      validate_form_field_identity(field, "#{path}.options[#{index}]")

      next unless field["field_type"] == "select"
      next if usable_choices?(field["select_options"])

      add_error("#{path}.options[#{index}].select_options", "missing_select_options",
                field["select_options"],
                "Field #{field['name'].inspect} is a select and lists no usable choices. " \
                "Give it select_options as [{\"label\": ..., \"value\": ...}] — a " \
                "select with none renders an empty dropdown nobody can answer.")
    end
  end

  # ImportSchemaGenerator publishes `name` and `label` as required on every form
  # field, and the agent prompt is generated from that schema — so until this ran
  # the schema and the half that writes disagreed. A blank `name` is not
  # cosmetic: process_form_step writes each response into the run's variables
  # under its field name, so two nameless fields collide on the key "" and no
  # condition can ever test either.
  def validate_form_field_identity(field, field_path)
    %w[name label].each do |key|
      next if field[key].to_s.strip.present?

      add_error("#{field_path}.#{key}", "missing_required_field", field[key],
                "A form field needs a #{key}.")
    end
  end

  # Choices the runner can actually render.
  #
  # Presence is not enough, and checking only for a non-empty Array was the first
  # version of this. `["IVR", "Link"]` is a plausible shape for an agent to reach
  # for and it passed — then `scenarios/_form_step` evaluates `opt["value"] ||
  # opt["label"]` against a String, which is String#[] doing a substring lookup
  # and answering nil for both. The result is a dropdown of blank options: the
  # exact thing this code exists to refuse, reached by a shape the published
  # schema already forbids. The validator is the half that writes, so it is the
  # half that has to agree.
  def usable_choices?(choices)
    choices.is_a?(Array) && choices.any? &&
      choices.all? { |c| c.is_a?(Hash) && c["label"].present? && c["value"].present? }
  end

  def validate_step_transitions(step, type, path)
    transitions = step["transitions"]

    if type == "resolve"
      if transitions.present?
        add_error("#{path}.transitions", "unexpected_transitions", transitions,
                  "A resolve step ends the workflow and must have no transitions.")
      end
      return
    end

    # A sub_flow that does not return ends this workflow, so it takes no
    # transitions for the same reason a resolve does not. Without this the app
    # exported a workflow containing a handoff to a file it would then refuse to
    # read back.
    #
    # Scoped to the flag being explicitly false: a returning sub_flow with no
    # transitions is still the dangling step this rule was written for.
    if type == "sub_flow" && step["sub_flow_returns"] == false
      if transitions.present?
        add_error("#{path}.transitions", "unexpected_transitions", transitions,
                  "A sub_flow with sub_flow_returns false hands the run over and " \
                  "must have no transitions.")
      end
      return
    end

    return if transitions.is_a?(Array) && transitions.any?

    add_error("#{path}.transitions", "missing_transitions", transitions,
              "Every step except resolve needs at least one transition. " \
              "This dialect does not infer them.")
  end

  def validate_transition_targets(steps, known_ids, workflow_path)
    steps.each_with_index do |step, index|
      next unless step.is_a?(Hash) && step["transitions"].is_a?(Array)

      step["transitions"].each_with_index do |transition, t_index|
        path = "#{workflow_path}.steps[#{index}].transitions[#{t_index}].target_id"
        target = transition.is_a?(Hash) ? transition["target_id"] : nil
        next if known_ids.include?(target)

        # "in this workflow", not "in this file": a file may now hold several,
        # and a transition never crosses between them — that is what sub_flow is.
        add_error(path, "dangling_transition_target", target,
                  "No step in this workflow has id #{target.inspect}.")
      end
    end
  end

  # The dialect says target_id — an agent told "uuid" reaches for SecureRandom
  # instead of another step's id. WorkflowImporter reads target_uuid. Translate
  # once, here, so nothing downstream needs to know the wire name differs.
  def normalize(workflow)
    normalized = workflow.deep_dup
    Array(normalized["steps"]).each do |step|
      next unless step.is_a?(Hash) && step["transitions"].is_a?(Array)

      step["transitions"] = step["transitions"].map do |transition|
        transition.merge("target_uuid" => transition["target_id"]).except("target_id")
      end
    end
    normalized
  end

  def step_id_pattern
    @step_id_pattern ||= Regexp.new(ImportSchemaGenerator::STEP_ID_PATTERN)
  end

  def excluded_field_names
    @excluded_field_names ||= ImportSchemaGenerator::EXCLUDED_FIELDS.map(&:to_s) +
                              ImportSchemaGenerator::EXCLUDED_WIRE_KEYS
  end

  def allowed_keys_for(type)
    @allowed_keys ||= {}
    @allowed_keys[type] ||= schema_branch(type)["properties"].keys
  end

  def workflow_schema_properties
    schema.dig("$defs", "workflow", "properties")
  end

  def schema
    @schema ||= ImportSchemaGenerator.call
  end

  def schema_branch(type)
    schema["$defs"]["step"]["oneOf"].find { |b| b["properties"]["type"]["const"] == type }
  end

  # --- reporting -------------------------------------------------------------

  # Always returns nil, so a caller can `return add_error(...)` to record and bail.
  def add_error(path, code, value, message, expected: nil)
    error = { path:, code:, message:, value: }
    error[:expected] = expected if expected
    @errors << error
    nil
  end

  def add_warning(path, code, value, message)
    @warnings << { path:, code:, message:, value: }
    nil
  end

  def report(workflows_data: nil, placements: nil)
    Report.new(errors: @errors, warnings: @warnings, workflows_data:, placements:)
  end
end
