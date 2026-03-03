# Workflow Import Parser Service
# Base class for all import parsers
# Updated for Graph Mode default support
module WorkflowParsers
  class BaseParser
    include ConditionNegation

    attr_reader :file_content, :errors, :warnings

    def initialize(file_content)
      @file_content = file_content
      @errors = []
      @warnings = []
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

    # Convert parsed data to Kizuflow workflow format
    # Now includes Graph Mode support with automatic conversion
    def to_workflow_data(parsed_data)
      steps = normalize_steps(parsed_data[:steps] || [])
      resolve_subflow_titles(steps)

      # Detect if input is already in graph format or needs conversion
      is_graph_format = detect_graph_format(steps)
      parsed_data[:graph_mode] == true || is_graph_format

      # Ensure all steps have UUIDs
      ensure_step_uuids(steps)

      # Convert linear format to graph format if needed (Graph Mode is default)
      unless is_graph_format
        steps = convert_to_graph_format(steps)
        add_warning("Converted from linear format to Graph Mode") unless steps.empty?
      end

      # Determine start node UUID
      start_node_uuid = parsed_data[:start_node_uuid] || steps.first&.dig('id')

      # Validate graph structure
      validate_graph_structure(steps, start_node_uuid) if steps.any?

      {
        title: parsed_data[:title] || "Imported Workflow",
        description: parsed_data[:description] || "",
        graph_mode: true, # Always import as Graph Mode (new default)
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

    # Detect if steps are already in graph format (have transitions)
    def detect_graph_format(steps)
      return false unless steps.is_a?(Array) && steps.any?

      # If any step has a non-empty transitions array, it's graph format
      steps.any? do |step|
        step.is_a?(Hash) && step['transitions'].is_a?(Array) && step['transitions'].any?
      end
    end

    # Ensure all steps have UUIDs
    def ensure_step_uuids(steps)
      return unless steps.is_a?(Array)

      steps.each do |step|
        next unless step.is_a?(Hash)

        step['id'] ||= SecureRandom.uuid
      end
    end

    # Convert linear format steps to graph format with explicit transitions
    def convert_to_graph_format(steps)
      return [] unless steps.is_a?(Array) && steps.any?

      # Build title-to-id map for path resolution
      title_to_id = {}
      steps.each { |s| title_to_id[s['title']] = s['id'] if s.is_a?(Hash) && s['title'] && s['id'] }

      steps.each_with_index do |step, index|
        next unless step.is_a?(Hash)

        step['transitions'] ||= []

        case step['type']
        when 'resolve'
          # Resolve steps are terminal - no transitions
          step['transitions'] = []
        else
          # Sequential steps: question, action, message, escalate, sub_flow
          convert_sequential_to_graph(step, index, steps, title_to_id)
        end
      end

      steps
    end

    # Convert sequential step to graph format
    def convert_sequential_to_graph(step, index, steps, title_to_id)
      transitions = step['transitions'] || []

      # Handle jumps (conditional transitions)
      if step['jumps'].is_a?(Array)
        step['jumps'].each do |jump|
          condition = jump['condition'] || jump[:condition]
          next_step_id = jump['next_step_id'] || jump[:next_step_id]

          next unless next_step_id.present?

          target_uuid = resolve_path_to_uuid(next_step_id, title_to_id)
          next unless target_uuid

          transitions << {
            'target_uuid' => target_uuid,
            'condition' => condition.presence,
            'label' => condition.present? ? "Jump: #{condition}" : nil
          }
        end
      end

      # Add default transition to next step if not last and no unconditional transition
      if index < steps.length - 1
        next_step = steps[index + 1]
        has_default = transitions.any? { |t| t['condition'].blank? }
        unless has_default
          transitions << {
            'target_uuid' => next_step['id'],
            'condition' => nil,
            'label' => nil
          }
        end
      end

      step['transitions'] = transitions
    end

    # Resolve a path reference (title, ID, or "Step N") to a UUID
    def resolve_path_to_uuid(path, title_to_id)
      return nil if path.blank?

      # Already a UUID?
      if path.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i) && title_to_id.values.include?(path)
        return path
      end

      # Direct title match
      return title_to_id[path] if title_to_id.key?(path)

      # Case-insensitive title match
      title_to_id.each do |title, id|
        return id if title.downcase == path.downcase
      end

      nil
    end

    # Validate graph structure after conversion
    def validate_graph_structure(steps, start_uuid)
      return if steps.empty?

      # Build steps hash for validator
      steps_hash = {}
      steps.each { |s| steps_hash[s['id']] = s if s.is_a?(Hash) && s['id'] }

      validator = GraphValidator.new(steps_hash, start_uuid)
      unless validator.valid?
        validator.errors.each do |error|
          add_warning("Graph validation: #{error}")
        end
      end
    rescue NameError
      # GraphValidator not loaded - skip validation during parse
      # Will be validated on workflow save
    end

    # Resolve target_workflow_title to target_workflow_id for sub_flow steps
    # Queries published workflows by title (case-insensitive) and sets the ID.
    # If target_workflow_id is already set, title resolution is skipped.
    # Unresolved or ambiguous titles mark the step as _import_incomplete.
    def resolve_subflow_titles(steps)
      return unless steps.is_a?(Array)

      subflow_steps = steps.select { |s| s.is_a?(Hash) && s['type'] == 'sub_flow' && s['target_workflow_title'].present? }
      return if subflow_steps.empty?

      subflow_steps.each do |step|
        # ID takes precedence — skip title resolution if already set
        if step['target_workflow_id'].present?
          step.delete('target_workflow_title')
          next
        end

        title = step['target_workflow_title'].to_s.strip
        if title.blank?
          step.delete('target_workflow_title')
          next
        end

        # Case-insensitive search among published workflows only
        matches = Workflow.where(status: 'published').where('LOWER(title) = LOWER(?)', title)

        if matches.count == 1
          step['target_workflow_id'] = matches.first.id
          add_warning("Sub-flow step '#{step['title']}': Resolved target workflow title '#{title}' to workflow ##{matches.first.id}")
        elsif matches.count == 0
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

        # Clean up transient field — not persisted to DB
        step.delete('target_workflow_title')
      end
    end

    # Normalize steps to ensure they match Kizuflow format
    def normalize_steps(steps)
      return [] unless steps.is_a?(Array)

      normalized_steps = steps.map.with_index do |step, index|
        normalize_single_step(step, index)
      end.compact

      # Assign UUIDs before resolving step references (needed for transition resolution)
      ensure_step_uuids(normalized_steps)

      # Resolve step number references for markdown imports
      if self.class.name.include?('MarkdownParser')
        normalized_steps = resolve_step_references(normalized_steps)
      end

      # Mark decision steps as incomplete if they reference non-existent steps
      validate_branch_references(normalized_steps)

      normalized_steps
    end

    # Normalize a single step
    def normalize_single_step(step, index)
      return nil unless step.is_a?(Hash)

      normalized = {
        'id' => step['id'] || step[:id],
        'type' => step[:type] || step['type'] || 'action',
        'title' => step[:title] || step['title'] || "Step #{index + 1}",
        'description' => step[:description] || step['description'] || ''
      }

      # Normalize type-specific fields
      case normalized['type']
      when 'question'
        normalized['question'] = step[:question] || step['question'] || ''
        normalized['answer_type'] = step[:answer_type] || step['answer_type'] || 'text'
        normalized['variable_name'] = step[:variable_name] || step['variable_name'] || ''
        normalized['options'] = normalize_options(step[:options] || step['options'] || [])
      when 'decision', 'simple_decision'
        # Auto-convert deprecated decision types to question
        normalized['type'] = 'question'
        normalized['question'] = step[:title] || step['title'] || ''
        normalized['answer_type'] = 'text'
        normalized['variable_name'] = ''
        normalized['options'] = []
        normalized['_import_converted'] = true
        normalized['_import_converted_from'] = step[:type] || step['type']
        add_warning("Converted deprecated '#{step[:type] || step['type']}' step '#{normalized['title']}' to question")
      when 'checkpoint'
        # Auto-convert deprecated checkpoint type to message
        normalized['type'] = 'message'
        normalized['content'] = step[:checkpoint_message] || step['checkpoint_message'] || ''
        normalized['_import_converted'] = true
        normalized['_import_converted_from'] = 'checkpoint'
        add_warning("Converted deprecated 'checkpoint' step '#{normalized['title']}' to message")
      when 'action'
        normalized['instructions'] = step[:instructions] || step['instructions'] || ''
        normalized['action_type'] = step[:action_type] || step['action_type'] || ''
      when 'sub_flow'
        normalized['target_workflow_id'] = step[:target_workflow_id] || step['target_workflow_id']
        normalized['target_workflow_title'] = step[:target_workflow_title] || step['target_workflow_title']
        normalized['variable_mapping'] = step[:variable_mapping] || step['variable_mapping'] || {}
      when 'message'
        normalized['content'] = step[:content] || step['content'] || ''
      when 'escalate'
        normalized['target_type'] = step[:target_type] || step['target_type'] || ''
        normalized['priority'] = step[:priority] || step['priority'] || 'normal'
        normalized['target_id'] = step[:target_id] || step['target_id']
        normalized['reason'] = step[:reason] || step['reason'] || ''
      when 'resolve'
        normalized['resolution_type'] = step[:resolution_type] || step['resolution_type'] || 'success'
        normalized['resolution_notes'] = step[:resolution_notes] || step['resolution_notes'] || ''
      end

      # Preserve transitions if already present (graph format import)
      if (step['transitions'] || step[:transitions]).is_a?(Array)
        normalized['transitions'] = normalize_transitions(step['transitions'] || step[:transitions])
      end

      # Preserve jumps for linear format
      if (step['jumps'] || step[:jumps]).is_a?(Array)
        normalized['jumps'] = step['jumps'] || step[:jumps]
      end

      # Preserve import conversion flags from upstream parsers
      if step[:_import_converted] || step['_import_converted']
        normalized['_import_converted'] = true
        normalized['_import_converted_from'] = step[:_import_converted_from] || step['_import_converted_from']
      end

      # Mark incomplete steps
      normalized['_import_incomplete'] = is_step_incomplete?(normalized)
      normalized['_import_errors'] = step_errors(normalized) if normalized['_import_incomplete']

      normalized
    end

    # Normalize transitions array
    def normalize_transitions(transitions)
      return [] unless transitions.is_a?(Array)

      transitions.map do |t|
        next nil unless t.is_a?(Hash)

        {
          'target_uuid' => t['target_uuid'] || t[:target_uuid],
          'condition' => t['condition'] || t[:condition],
          'label' => t['label'] || t[:label]
        }.compact
      end.compact
    end

    def normalize_options(options)
      return [] unless options.is_a?(Array)

      options.map do |opt|
        if opt.is_a?(Hash)
          {
            'label' => opt[:label] || opt['label'] || opt[:value] || opt['value'] || '',
            'value' => opt[:value] || opt['value'] || opt[:label] || opt['label'] || ''
          }
        else
          { 'label' => opt.to_s, 'value' => opt.to_s }
        end
      end
    end

    def normalize_branches(branches)
      return [] unless branches.is_a?(Array)

      branches.map do |branch|
        {
          'condition' => branch[:condition] || branch['condition'] || '',
          'path' => branch[:path] || branch['path'] || ''
        }
      end
    end

    REQUIRED_STEP_FIELDS = {
      'question' => { field: 'question', message: 'Question text is required' },
      'action' => { field: 'instructions', message: 'Instructions are required' },
      'resolve' => { field: 'resolution_type', message: 'Resolution type is required' }
    }.freeze

    def is_step_incomplete?(step)
      config = REQUIRED_STEP_FIELDS[step['type']]
      config ? step[config[:field]].blank? : false
    end

    def step_errors(step)
      config = REQUIRED_STEP_FIELDS[step['type']]
      return [] unless config
      step[config[:field]].blank? ? [config[:message]] : []
    end

    # No-op: decision step branches are no longer supported
    def validate_branch_references(normalized_steps)
    end

    # Resolve step number references (e.g., "Step 3" -> actual step title or ID)
    def resolve_step_references(normalized_steps)
      return normalized_steps unless normalized_steps.is_a?(Array) && normalized_steps.length > 0

      step_title_map, step_id_map, title_to_id = build_reference_maps(normalized_steps)
      resolve_references_in_steps(normalized_steps, step_title_map, step_id_map, title_to_id)
    end

    # Build lookup maps from step numbers/titles to titles and IDs.
    def build_reference_maps(normalized_steps)
      step_title_map = {}  # Maps "Step 2" -> "Step 2: Select Issue Type"
      step_id_map = {}     # Maps "Step 2" -> step['id'] (UUID)
      title_to_id = {}     # Maps "Step 2: Select Issue Type" -> step['id']

      normalized_steps.each_with_index do |step, index|
        step_num = index + 1
        step_title = step['title'] || "Step #{step_num}"
        step_id = step['id']

        title_to_id[step_title] = step_id if step_id

        variations = [
          "Step #{step_num}", "Step #{step_num}:",
          "step #{step_num}", "step #{step_num}:",
          step_num.to_s,
          "Go to Step #{step_num}", "go to step #{step_num}"
        ]

        variations.each do |v|
          step_title_map[v] = step_title
          step_id_map[v] = step_id if step_id
        end

        next unless step_title =~ /^Step\s+(\d+)/i

        step_num_from_title = ::Regexp.last_match(1).to_i
        step_title_map["Step #{step_num_from_title}"] = step_title
        step_title_map["step #{step_num_from_title}"] = step_title
        step_id_map["Step #{step_num_from_title}"] = step_id if step_id
        step_id_map["step #{step_num_from_title}"] = step_id if step_id
      end

      [step_title_map, step_id_map, title_to_id]
    end

    # Resolve references in branch paths, else_path, and transition target_uuids.
    def resolve_references_in_steps(normalized_steps, step_title_map, step_id_map, title_to_id)
      normalized_steps.map do |step|
        resolved_step = step.dup

        if resolved_step['branches'].present? && resolved_step['branches'].is_a?(Array)
          resolved_step['branches'] = resolved_step['branches'].map do |branch|
            resolved_branch = branch.dup
            path = resolved_branch['path']
            if path.present?
              resolved_path = resolve_step_reference(path, step_title_map, normalized_steps)
              resolved_branch['path'] = resolved_path || path
            end
            resolved_branch
          end
        end

        if resolved_step['else_path'].present?
          resolved_else_path = resolve_step_reference(resolved_step['else_path'], step_title_map, normalized_steps)
          resolved_step['else_path'] = resolved_else_path || resolved_step['else_path']
        end

        if resolved_step['transitions'].present? && resolved_step['transitions'].is_a?(Array)
          resolved_step['transitions'] = resolved_step['transitions'].map do |transition|
            resolved_transition = transition.dup
            target = resolved_transition['target_uuid']
            if target.present? && !target.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
              resolved_id = resolve_step_reference_to_id(target, step_id_map, title_to_id, normalized_steps)
              resolved_transition['target_uuid'] = resolved_id || target
            end
            resolved_transition
          end
        end

        resolved_step
      end
    end

    # Resolve a step reference to a step ID (UUID)
    def resolve_step_reference_to_id(ref, step_id_map, title_to_id, normalized_steps)
      return nil if ref.blank?

      # Direct match in step_id_map (handles "Step 2" -> uuid)
      return step_id_map[ref] if step_id_map.key?(ref)
      return step_id_map[ref.strip] if step_id_map.key?(ref.strip)

      # Try title_to_id (handles full titles)
      return title_to_id[ref] if title_to_id.key?(ref)
      return title_to_id[ref.strip] if title_to_id.key?(ref.strip)

      # Extract step number from "Go to Step X" patterns
      if ref =~ /step\s+(\d+)/i
        step_num = ::Regexp.last_match(1).to_i
        if step_num > 0 && step_num <= normalized_steps.length
          return step_id_map["Step #{step_num}"]
        end
      end

      # Case-insensitive fallback
      step_id_map.each do |key, id|
        if key.downcase == ref.downcase || key.downcase.strip == ref.downcase.strip
          return id
        end
      end

      title_to_id.each do |title, id|
        if title.downcase == ref.downcase
          return id
        end
      end

      nil
    end

    # Resolve a single step reference
    def resolve_step_reference(path, step_title_map, normalized_steps)
      # Direct match
      return step_title_map[path] if step_title_map.key?(path)
      return step_title_map[path.strip] if step_title_map.key?(path.strip)

      # Extract step number from "Go to Step X" patterns
      if path =~ /step\s+(\d+)/i
        step_num = ::Regexp.last_match(1).to_i
        if step_num > 0 && step_num <= normalized_steps.length
          return step_title_map["Step #{step_num}"]
        end
      end

      # Case-insensitive fallback
      step_title_map.each do |key, title|
        if key.downcase == path.downcase || key.downcase.strip == path.downcase.strip
          return title
        end
      end

      nil
    end
  end
end
