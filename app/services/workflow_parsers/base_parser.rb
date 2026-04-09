# Workflow Import Parser Service
# Base class for all import parsers.
# Orchestrates parsing by delegating step normalisation to StepNormalizer
# and transition/graph building to TransitionBuilder.
module WorkflowParsers
  class BaseParser
    include ConditionNegation

    attr_reader :file_content, :errors, :warnings

    def initialize(file_content)
      @file_content        = file_content
      @errors              = []
      @warnings            = []
      @step_normalizer     = StepNormalizer.new
      @transition_builder  = TransitionBuilder.new
    end

    def parse
      raise NotImplementedError, "Subclasses must implement parse method"
    end

    def valid?
      @errors.empty?
    end

    protected

    def add_error(message)
      @errors << message
    end

    def add_warning(message)
      @warnings << message
    end

    # Convert parsed data to TurboFlows workflow format.
    # Always produces graph-mode output.
    def to_workflow_data(parsed_data)
      steps = normalize_steps(parsed_data[:steps] || [])
      resolve_subflow_titles(steps)

      is_graph_format = detect_graph_format(steps)
      parsed_data[:graph_mode] == true || is_graph_format

      ensure_step_uuids(steps)

      unless is_graph_format
        steps = convert_to_graph_format(steps)
        add_warning("Converted from linear format to Graph Mode") unless steps.empty?
      end

      start_node_uuid = parsed_data[:start_node_uuid] || steps.first&.dig('id')

      validate_graph_structure(steps, start_node_uuid) if steps.any?

      {
        title: parsed_data[:title] || "Imported Workflow",
        description: parsed_data[:description] || "",
        graph_mode: true,
        start_node_uuid: start_node_uuid,
        steps: steps,
        import_metadata: {
          source_format: self.class.name.demodulize.downcase.gsub('parser', ''),
          imported_at: Time.current.iso8601,
          original_format: is_graph_format ? 'graph' : 'linear',
          warnings: @warnings,
          errors: @errors
        }
      }
    end

    # ---------------------------------------------------------------------------
    # Delegation to StepNormalizer
    # ---------------------------------------------------------------------------

    def normalize_steps(steps)
      normalized = @step_normalizer.normalize(steps, parser_class_name: self.class.name)
      collect_collaborator_warnings(@step_normalizer)
      normalized
    end

    def normalize_single_step(step, index)
      result = @step_normalizer.normalize_single_step(step, index)
      collect_collaborator_warnings(@step_normalizer)
      result
    end

    def normalize_transitions(transitions)
      @step_normalizer.normalize_transitions(transitions)
    end

    def normalize_options(options)
      @step_normalizer.normalize_options(options)
    end

    def normalize_branches(branches)
      @step_normalizer.normalize_branches(branches)
    end

    def step_incomplete?(step)
      @step_normalizer.incomplete?(step)
    end

    def step_errors(step)
      @step_normalizer.errors_for(step)
    end

    # No-op: decision step branches are no longer supported
    def validate_branch_references(_steps); end

    # Resolve step number references (e.g., "Step 3" → actual step title or ID)
    def resolve_step_references(normalized_steps)
      @step_normalizer.resolve_step_references(normalized_steps)
    end

    def build_reference_maps(normalized_steps)
      # Delegate via resolve_step_references — retained for back-compat with
      # any subclass that calls it directly.
      @step_normalizer.send(:build_reference_maps, normalized_steps)
    end

    def resolve_references_in_steps(normalized_steps, step_title_map, step_id_map, title_to_id)
      @step_normalizer.send(:resolve_references_in_steps,
                            normalized_steps, step_title_map, step_id_map, title_to_id)
    end

    def resolve_step_reference(path, step_title_map, normalized_steps)
      @step_normalizer.send(:resolve_step_reference, path, step_title_map, normalized_steps)
    end

    def resolve_step_reference_to_id(ref, step_id_map, title_to_id, normalized_steps)
      @step_normalizer.send(:resolve_step_reference_to_id,
                            ref, step_id_map, title_to_id, normalized_steps)
    end

    # ---------------------------------------------------------------------------
    # Delegation to TransitionBuilder
    # ---------------------------------------------------------------------------

    def detect_graph_format(steps)
      @transition_builder.graph_format?(steps)
    end

    def ensure_step_uuids(steps)
      @transition_builder.ensure_uuids(steps)
    end

    def convert_to_graph_format(steps)
      result = @transition_builder.convert_to_graph(steps)
      collect_collaborator_warnings(@transition_builder)
      result
    end

    def resolve_path_to_uuid(path, title_to_id)
      @transition_builder.resolve_path_to_uuid(path, title_to_id)
    end

    def validate_graph_structure(steps, start_uuid)
      @transition_builder.validate_graph_structure(steps, start_uuid)
      collect_collaborator_warnings(@transition_builder)
    end

    # ---------------------------------------------------------------------------
    # Sub-flow title resolution (requires DB; stays in orchestrator)
    # ---------------------------------------------------------------------------

    # Resolve target_workflow_title to target_workflow_id for sub_flow steps.
    # Queries published workflows by title (case-insensitive).
    # If target_workflow_id is already set, title resolution is skipped.
    # Unresolved or ambiguous titles mark the step as _import_incomplete.
    def resolve_subflow_titles(steps)
      return unless steps.is_a?(Array)

      subflow_steps = steps.select { |s| s.is_a?(Hash) && s['type'] == 'sub_flow' && s['target_workflow_title'].present? }
      return if subflow_steps.empty?

      subflow_steps.each do |step|
        if step['target_workflow_id'].present?
          step.delete('target_workflow_title')
          next
        end

        title = step['target_workflow_title'].to_s.strip
        if title.blank?
          step.delete('target_workflow_title')
          next
        end

        matches = Workflow.where(status: 'published').where('LOWER(title) = LOWER(?)', title)

        if matches.one?
          step['target_workflow_id'] = matches.first.id
          add_warning("Sub-flow step '#{step['title']}': Resolved target workflow title '#{title}' to workflow ##{matches.first.id}")
        elsif matches.none?
          step['_import_incomplete'] = true
          step['_import_errors'] ||= []
          step['_import_errors'] << "Target workflow '#{title}' not found among published workflows"
          add_warning("Sub-flow step '#{step['title']}': No published workflow found with title '#{title}'")
        else
          step['_import_incomplete'] = true
          step['_import_errors'] ||= []
          matching_titles = matches.map { |w| "#{w.title} (##{w.id})" }.join(', ')
          step['_import_errors'] << "Multiple published workflows match title '#{title}': #{matching_titles}"
          add_warning("Sub-flow step '#{step['title']}': Ambiguous title '#{title}' matches #{matches.count} published workflows")
        end

        step.delete('target_workflow_title')
      end
    end

    private

    # Drain any new warnings accumulated by a collaborator since the last drain.
    def collect_collaborator_warnings(collaborator)
      collaborator.warnings.each { |w| @warnings << w unless @warnings.include?(w) }
    end
  end
end
