# JSON Parser for TurboFlows workflow imports
# Updated for Graph Mode support
require 'json'

module WorkflowParsers
  class JsonParser < BaseParser
    def parse
      data = JSON.parse(@file_content)

      # Handle both direct workflow objects and wrapped formats
      workflow_data = if data['workflow']
                        data['workflow']
                      elsif data['title'] || data['steps']
                        data
                      else
                        add_error("Invalid JSON structure: expected workflow object with 'title' and 'steps'")
                        return nil
                      end

      # Extract core fields
      title = workflow_data['title'] || workflow_data[:title]
      description = workflow_data['description'] || workflow_data[:description] || ''
      steps = workflow_data['steps'] || workflow_data[:steps] || []

      # Extract Graph Mode fields (new in version 2.0)
      graph_mode = workflow_data['graph_mode']
      start_node_uuid = workflow_data['start_node_uuid']

      groups = workflow_data['groups'] || workflow_data[:groups] || []
      folder = workflow_data['folder'] || workflow_data[:folder]
      tags = workflow_data['tags'] || workflow_data[:tags] || []

      if title.blank?
        add_error("Workflow title is required")
        return nil
      end

      unless steps.is_a?(Array)
        add_error("Steps must be an array")
        return nil
      end

      # Normalize step keys and preserve graph-specific fields
      normalized_steps = normalize_json_steps(steps)

      parsed_data = {
        title: title,
        description: description,
        graph_mode: graph_mode,
        start_node_uuid: start_node_uuid,
        groups: groups,
        folder: folder,
        tags: tags,
        steps: normalized_steps
      }

      to_workflow_data(parsed_data)
    rescue JSON::ParserError => e
      add_error("Invalid JSON format: #{e.message}")
      nil
    rescue StandardError => e
      add_error("Error parsing JSON: #{e.message}")
      nil
    end

    private

    # Normalize JSON steps preserving all graph-specific fields
    def normalize_json_steps(steps)
      steps.map do |step|
        next step unless step.is_a?(Hash)

        # Convert symbol keys to string keys
        normalized = step.stringify_keys

        # Recursively normalize nested structures
        if normalized['options'].is_a?(Array)
          normalized['options'] = normalized['options'].map { |o| o.is_a?(Hash) ? o.stringify_keys : o }
        end

        if normalized['branches'].is_a?(Array)
          normalized['branches'] = normalized['branches'].map { |b| b.is_a?(Hash) ? b.stringify_keys : b }
        end

        if normalized['transitions'].is_a?(Array)
          normalized['transitions'] = normalized['transitions'].map { |t| t.is_a?(Hash) ? t.stringify_keys : t }
        end

        if normalized['jumps'].is_a?(Array)
          normalized['jumps'] = normalized['jumps'].map { |j| j.is_a?(Hash) ? j.stringify_keys : j }
        end

        if normalized['output_fields'].is_a?(Array)
          normalized['output_fields'] = normalized['output_fields'].map { |f| f.is_a?(Hash) ? f.stringify_keys : f }
        end

        if normalized['variable_mapping'].is_a?(Hash)
          normalized['variable_mapping'] = normalized['variable_mapping'].stringify_keys
        end

        normalized
      end
    end
  end
end
