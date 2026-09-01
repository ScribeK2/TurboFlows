# YAML Parser for TurboFlows workflow imports
# Updated for Graph Mode support
require 'yaml'

module WorkflowParsers
  class YamlParser < BaseParser
    def parse
      data = YAML.safe_load(@file_content, permitted_classes: [Symbol])

      # Handle both direct workflow objects and wrapped formats
      workflow_data = if data['workflow'] || data[:workflow]
                        data['workflow'] || data[:workflow]
                      elsif data['title'] || data[:title] || data['steps'] || data[:steps]
                        data
                      else
                        add_error("Invalid YAML structure: expected workflow object with 'title' and 'steps'")
                        return nil
                      end

      # Convert symbol keys to string keys for consistency
      workflow_data = normalize_keys(workflow_data) if workflow_data.is_a?(Hash)

      # Extract core fields
      title = workflow_data['title'] || ''
      description = workflow_data['description'] || ''
      steps = workflow_data['steps'] || []

      # Extract Graph Mode fields
      graph_mode = workflow_data['graph_mode']
      start_node_uuid = workflow_data['start_node_uuid']

      groups = workflow_data['groups'] || []
      folder = workflow_data['folder']
      tags = workflow_data['tags'] || []

      if title.blank?
        add_error("Workflow title is required")
        return nil
      end

      unless steps.is_a?(Array)
        add_error("Steps must be an array")
        return nil
      end

      parsed_data = {
        title: title,
        description: description,
        graph_mode: graph_mode,
        start_node_uuid: start_node_uuid,
        groups: groups,
        folder: folder,
        tags: tags,
        steps: normalize_step_keys(steps)
      }

      to_workflow_data(parsed_data)
    rescue Psych::SyntaxError => e
      add_error("Invalid YAML syntax: #{e.message}")
      nil
    rescue StandardError => e
      add_error("Error parsing YAML: #{e.message}")
      nil
    end

    private

    def normalize_keys(hash)
      return hash unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(key, value), normalized|
        normalized_key = key.is_a?(Symbol) ? key.to_s : key
        normalized_value = if value.is_a?(Hash)
                             normalize_keys(value)
                           elsif value.is_a?(Array)
                             value.map { |item| item.is_a?(Hash) ? normalize_keys(item) : item }
                           else
                             value
                           end
        normalized[normalized_key] = normalized_value
      end
    end

    def normalize_step_keys(steps)
      steps.map do |step|
        if step.is_a?(Hash)
          normalize_keys(step)
        else
          step
        end
      end
    end
  end
end
