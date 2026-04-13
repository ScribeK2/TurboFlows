# Normalises raw step hashes from import parsers into the canonical
# TurboFlows step format.  Handles field defaults, type coercion,
# deprecated-type conversion, completeness checking, and step-number
# reference resolution for Markdown imports.
module WorkflowParsers
  class StepNormalizer
    REQUIRED_STEP_FIELDS = {
      'question' => { field: 'question', message: 'Question text is required' },
      'action' => { field: 'instructions', message: 'Instructions are required' },
      'resolve' => { field: 'resolution_type', message: 'Resolution type is required' }
    }.freeze

    attr_reader :warnings

    def initialize
      @warnings = []
    end

    # Normalize steps to ensure they match TurboFlows format.
    # Returns a new array of normalised step hashes (nils compacted out).
    def normalize(steps, parser_class_name: nil)
      return [] unless steps.is_a?(Array)

      normalized = steps.map.with_index do |step, index|
        normalize_single_step(step, index)
      end.compact

      # Assign UUIDs before resolving step references
      ensure_uuids(normalized)

      # Resolve step number references for Markdown imports
      if parser_class_name&.include?('MarkdownParser')
        normalized = resolve_step_references(normalized)
      end

      # No-op hook for branch reference validation (kept for extension)
      validate_branch_references(normalized)

      normalized
    end

    # Normalise a single step hash.  Returns nil for non-hash input.
    def normalize_single_step(step, index)
      return nil unless step.is_a?(Hash)

      normalized = {
        'id' => step['id'] || step[:id],
        'type' => step[:type] || step['type'] || 'action',
        'title' => step[:title] || step['title'] || "Step #{index + 1}",
        'description' => step[:description] || step['description'] || ''
      }

      apply_type_fields(normalized, step)
      preserve_transitions(normalized, step)
      preserve_jumps(normalized, step)
      preserve_conversion_flags(normalized, step)

      normalized['_import_incomplete'] = incomplete?(normalized)
      normalized['_import_errors']     = errors_for(normalized) if normalized['_import_incomplete']

      normalized
    end

    # Normalise a transitions array (symbol or string keys accepted).
    def normalize_transitions(transitions)
      return [] unless transitions.is_a?(Array)

      transitions.filter_map do |t|
        next unless t.is_a?(Hash)

        {
          'target_uuid' => t['target_uuid'] || t[:target_uuid],
          'condition' => t['condition'] || t[:condition],
          'label' => t['label'] || t[:label]
        }.compact
      end
    end

    # Normalise an options array (strings or hashes).
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

    # Normalise a branches array.
    def normalize_branches(branches)
      return [] unless branches.is_a?(Array)

      branches.map do |branch|
        {
          'condition' => branch[:condition] || branch['condition'] || '',
          'path' => branch[:path] || branch['path'] || ''
        }
      end
    end

    def incomplete?(step)
      config = REQUIRED_STEP_FIELDS[step['type']]
      config ? step[config[:field]].blank? : false
    end

    def errors_for(step)
      config = REQUIRED_STEP_FIELDS[step['type']]
      return [] unless config

      step[config[:field]].blank? ? [config[:message]] : []
    end

    # Ensure every step in the array has an 'id' key set to a UUID.
    def ensure_uuids(steps)
      return unless steps.is_a?(Array)

      steps.each do |step|
        next unless step.is_a?(Hash)

        step['id'] ||= SecureRandom.uuid
      end
    end

    # Resolve "Step N" / title references in transitions, branches, and
    # else_path fields.  Used only for Markdown imports.
    def resolve_step_references(normalized_steps)
      return normalized_steps unless normalized_steps.is_a?(Array) && normalized_steps.length.positive?

      step_title_map, step_id_map, title_to_id = build_reference_maps(normalized_steps)
      resolve_references_in_steps(normalized_steps, step_title_map, step_id_map, title_to_id)
    end

    private

    # -------------------------------------------------------------------------
    # Value normalisation
    # -------------------------------------------------------------------------

    RESOLUTION_TYPE_ALIASES = {
      'transferred' => 'transfer',
      'other'       => 'failure'
    }.freeze

    def normalize_resolution_type(value)
      raw = value.to_s.strip.downcase
      RESOLUTION_TYPE_ALIASES.fetch(raw, raw)
    end

    # -------------------------------------------------------------------------
    # Type-specific field extraction
    # -------------------------------------------------------------------------

    def apply_type_fields(normalized, step)
      case normalized['type']
      when 'question'
        normalized['question']       = step[:question]      || step['question']      || ''
        normalized['answer_type']    = step[:answer_type]   || step['answer_type']   || 'text'
        normalized['variable_name']  = step[:variable_name] || step['variable_name'] || ''
        normalized['options']        = normalize_options(step[:options] || step['options'] || [])
        normalized['can_resolve']    = step[:can_resolve]   || step['can_resolve']
      when 'decision', 'simple_decision'
        convert_decision_to_question(normalized, step)
      when 'checkpoint'
        convert_checkpoint_to_message(normalized, step)
      when 'action'
        normalized['instructions'] = step[:instructions] || step['instructions'] || ''
        normalized['action_type']  = step[:action_type]  || step['action_type']  || ''
        normalized['can_resolve']  = step[:can_resolve]  || step['can_resolve']
        normalized['output_fields'] = step[:output_fields] || step['output_fields'] if (step[:output_fields] || step['output_fields']).present?
      when 'sub_flow'
        normalized['target_workflow_id']    = step[:target_workflow_id]    || step['target_workflow_id']
        normalized['target_workflow_title'] = step[:target_workflow_title] || step['target_workflow_title']
        normalized['variable_mapping']      = step[:variable_mapping]      || step['variable_mapping'] || {}
      when 'message'
        normalized['content']     = step[:content]     || step['content']     || ''
        normalized['can_resolve'] = step[:can_resolve] || step['can_resolve']
      when 'escalate'
        normalized['target_type']    = step[:target_type]    || step['target_type']    || ''
        normalized['target_value']   = step[:target_value]   || step['target_value']   || step[:target_id] || step['target_id'] || ''
        normalized['priority']       = step[:priority]       || step['priority']       || 'normal'
        normalized['reason_required'] = step[:reason_required] || step['reason_required']
        normalized['notes']          = step[:notes]          || step['notes']          || step[:reason] || step['reason'] || ''
      when 'resolve'
        normalized['resolution_type']  = normalize_resolution_type(step[:resolution_type] || step['resolution_type'] || 'success')
        normalized['resolution_notes'] = step[:resolution_notes] || step['resolution_notes'] || ''
        normalized['description']      = step[:description]      || step['description']      || ''
        normalized['notes_required']   = step[:notes_required]   || step['notes_required']
        normalized['survey_trigger']   = step[:survey_trigger]   || step['survey_trigger']
      when 'form'
        normalized['options']      = step[:options] || step['options'] || []
        normalized['instructions'] = step[:instructions] || step['instructions'] || ''
      end
    end

    def convert_decision_to_question(normalized, step)
      original_type = step[:type] || step['type']
      normalized['type']                  = 'question'
      normalized['question']              = step[:title] || step['title'] || ''
      normalized['answer_type']           = 'text'
      normalized['variable_name']         = ''
      normalized['options']               = []
      normalized['_import_converted']     = true
      normalized['_import_converted_from'] = original_type
      @warnings << "Converted deprecated '#{original_type}' step '#{normalized['title']}' to question"
    end

    def convert_checkpoint_to_message(normalized, step)
      normalized['type']                  = 'message'
      normalized['content']               = step[:checkpoint_message] || step['checkpoint_message'] || ''
      normalized['_import_converted']     = true
      normalized['_import_converted_from'] = 'checkpoint'
      @warnings << "Converted deprecated 'checkpoint' step '#{normalized['title']}' to message"
    end

    # -------------------------------------------------------------------------
    # Field preservation helpers
    # -------------------------------------------------------------------------

    def preserve_transitions(normalized, step)
      raw = step['transitions'] || step[:transitions]
      normalized['transitions'] = normalize_transitions(raw) if raw.is_a?(Array)
    end

    def preserve_jumps(normalized, step)
      raw = step['jumps'] || step[:jumps]
      normalized['jumps'] = raw if raw.is_a?(Array)
    end

    def preserve_conversion_flags(normalized, step)
      return unless step[:_import_converted] || step['_import_converted']

      normalized['_import_converted']      = true
      normalized['_import_converted_from'] = step[:_import_converted_from] || step['_import_converted_from']
    end

    # -------------------------------------------------------------------------
    # Branch reference validation (no-op; kept for subclass extension)
    # -------------------------------------------------------------------------

    def validate_branch_references(_steps)
      # No-op: decision step branches are no longer supported
    end

    # -------------------------------------------------------------------------
    # Step reference resolution (Markdown imports)
    # -------------------------------------------------------------------------

    def build_reference_maps(normalized_steps)
      step_title_map = {}
      step_id_map    = {}
      title_to_id    = {}

      normalized_steps.each_with_index do |step, index|
        step_num = index + 1
        step_title = step['title'] || "Step #{step_num}"
        step_id    = step['id']

        title_to_id[step_title] = step_id if step_id

        variations = [
          "Step #{step_num}", "Step #{step_num}:",
          "step #{step_num}", "step #{step_num}:",
          step_num.to_s,
          "Go to Step #{step_num}", "go to step #{step_num}"
        ]

        variations.each do |v|
          step_title_map[v] = step_title
          step_id_map[v]    = step_id if step_id
        end

        next unless step_title =~ /^Step\s+(\d+)/i

        step_num_from_title = ::Regexp.last_match(1).to_i
        step_title_map["Step #{step_num_from_title}"] = step_title
        step_title_map["step #{step_num_from_title}"] = step_title
        step_id_map["Step #{step_num_from_title}"]    = step_id if step_id
        step_id_map["step #{step_num_from_title}"]    = step_id if step_id
      end

      [step_title_map, step_id_map, title_to_id]
    end

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
          resolved_else = resolve_step_reference(resolved_step['else_path'], step_title_map, normalized_steps)
          resolved_step['else_path'] = resolved_else || resolved_step['else_path']
        end

        if resolved_step['transitions'].present? && resolved_step['transitions'].is_a?(Array)
          resolved_step['transitions'] = resolved_step['transitions'].map do |transition|
            resolved_t = transition.dup
            target = resolved_t['target_uuid']
            if target.present? && !target.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
              resolved_id = resolve_step_reference_to_id(target, step_id_map, title_to_id, normalized_steps)
              resolved_t['target_uuid'] = resolved_id || target
            end
            resolved_t
          end
        end

        resolved_step
      end
    end

    def resolve_step_reference(path, step_title_map, normalized_steps)
      return step_title_map[path]       if step_title_map.key?(path)
      return step_title_map[path.strip] if step_title_map.key?(path.strip)

      if path =~ /step\s+(\d+)/i
        step_num = ::Regexp.last_match(1).to_i
        if step_num.positive? && step_num <= normalized_steps.length
          return step_title_map["Step #{step_num}"]
        end
      end

      step_title_map.each do |key, title|
        return title if key.downcase == path.downcase || key.downcase.strip == path.downcase.strip
      end

      nil
    end

    def resolve_step_reference_to_id(ref, step_id_map, title_to_id, normalized_steps)
      return nil if ref.blank?

      return step_id_map[ref]       if step_id_map.key?(ref)
      return step_id_map[ref.strip] if step_id_map.key?(ref.strip)

      return title_to_id[ref]       if title_to_id.key?(ref)
      return title_to_id[ref.strip] if title_to_id.key?(ref.strip)

      if ref =~ /step\s+(\d+)/i
        step_num = ::Regexp.last_match(1).to_i
        if step_num.positive? && step_num <= normalized_steps.length
          return step_id_map["Step #{step_num}"]
        end
      end

      step_id_map.each do |key, id|
        return id if key.downcase == ref.downcase || key.downcase.strip == ref.downcase.strip
      end

      title_to_id.each do |title, id|
        return id if title.downcase == ref.downcase
      end

      nil
    end
  end
end
