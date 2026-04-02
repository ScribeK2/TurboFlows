# Builds and validates transition data for workflow graph construction.
# Handles UUID assignment, graph format detection, linear-to-graph
# conversion, and post-conversion graph structure validation.
module WorkflowParsers
  class TransitionBuilder
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    # Returns true if any step in the array already has a non-empty
    # transitions array (i.e. the data is already in graph format).
    def graph_format?(steps)
      return false unless steps.is_a?(Array) && steps.any?

      steps.any? do |step|
        step.is_a?(Hash) && step['transitions'].is_a?(Array) && step['transitions'].any?
      end
    end

    # Ensure every step hash in the array has an 'id' key set to a UUID.
    # Mutates the array in place; returns nothing meaningful.
    def ensure_uuids(steps)
      return unless steps.is_a?(Array)

      steps.each do |step|
        next unless step.is_a?(Hash)

        step['id'] ||= SecureRandom.uuid
      end
    end

    # Convert a linear (sequential) step list to graph format by adding
    # explicit transitions between consecutive steps.
    # Returns the mutated steps array.
    def convert_to_graph(steps)
      return [] unless steps.is_a?(Array) && steps.any?

      title_to_id = {}
      steps.each { |s| title_to_id[s['title']] = s['id'] if s.is_a?(Hash) && s['title'] && s['id'] }

      steps.each_with_index do |step, index|
        next unless step.is_a?(Hash)

        step['transitions'] ||= []

        if step['type'] == 'resolve'
          step['transitions'] = []
        else
          build_sequential_transitions(step, index, steps, title_to_id)
        end
      end

      steps
    end

    # Normalise a raw transitions array (symbol or string keys accepted).
    def normalize_transitions(transitions)
      return [] unless transitions.is_a?(Array)

      transitions.filter_map do |t|
        next unless t.is_a?(Hash)

        {
          'target_uuid' => t['target_uuid'] || t[:target_uuid],
          'condition'   => t['condition']   || t[:condition],
          'label'       => t['label']       || t[:label]
        }.compact
      end
    end

    # Resolve a path string (title, UUID, or "Step N") to a step UUID
    # using the supplied title→UUID map.
    def resolve_path_to_uuid(path, title_to_id)
      return nil if path.blank?

      if path.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i) &&
         title_to_id.values.include?(path)
        return path
      end

      return title_to_id[path] if title_to_id.key?(path)

      title_to_id.each do |title, id|
        return id if title.downcase == path.downcase
      end

      nil
    end

    # Validate the graph structure using GraphValidator (if available).
    # Validation failures are appended to +warnings+.
    def validate_graph_structure(steps, start_uuid)
      return if steps.empty?

      steps_hash = {}
      steps.each { |s| steps_hash[s['id']] = s if s.is_a?(Hash) && s['id'] }

      validator = GraphValidator.new(steps_hash, start_uuid)
      unless validator.valid?
        validator.errors.each { |error| @warnings << "Graph validation: #{error}" }
      end
    rescue NameError
      # GraphValidator not loaded — skip; will be validated on workflow save
    end

    private

    def build_sequential_transitions(step, index, steps, title_to_id)
      transitions = step['transitions'] || []

      if step['jumps'].is_a?(Array)
        step['jumps'].each do |jump|
          condition    = jump['condition'] || jump[:condition]
          next_step_id = jump['next_step_id'] || jump[:next_step_id]

          next unless next_step_id.present?

          target_uuid = resolve_path_to_uuid(next_step_id, title_to_id)
          next unless target_uuid

          transitions << {
            'target_uuid' => target_uuid,
            'condition'   => condition.presence,
            'label'       => condition.present? ? "Jump: #{condition}" : nil
          }
        end
      end

      if index < steps.length - 1
        next_step   = steps[index + 1]
        has_default = transitions.any? { |t| t['condition'].blank? }
        unless has_default
          transitions << {
            'target_uuid' => next_step['id'],
            'condition'   => nil,
            'label'       => nil
          }
        end
      end

      step['transitions'] = transitions
    end
  end
end
