# CSV Parser for TurboFlows workflow imports
# Updated for Graph Mode support
require 'csv'

module WorkflowParsers
  class CsvParser < BaseParser
    # Valid step types for CSV import
    VALID_CSV_TYPES = %w[question action sub_flow message escalate resolve].freeze

    def parse
      csv = CSV.parse(@file_content, headers: true, header_converters: :symbol)

      if csv.headers.blank?
        add_error("CSV file must have a header row")
        return nil
      end

      # Required columns
      required_columns = %i[type title]
      missing_columns = required_columns - csv.headers
      if missing_columns.any?
        add_error("Missing required columns: #{missing_columns.join(', ')}")
        return nil
      end

      # Extract workflow metadata from first row or use defaults
      title = csv.headers.include?(:workflow_title) ? csv.first[:workflow_title] : nil
      title ||= csv.headers.include?(:title) ? csv.first[:title] : nil
      title ||= "Imported Workflow"

      description = csv.headers.include?(:workflow_description) ? csv.first[:workflow_description] : nil
      description ||= csv.headers.include?(:description) ? csv.first[:description] : nil
      description ||= ""

      # Parse steps from rows
      steps = []
      csv.each_with_index do |row, index|
        # Skip empty rows
        next if row[:type].blank? && row[:title].blank?

        step = parse_csv_row(row, index + 1)
        steps << step if step
      end

      if steps.empty?
        add_error("No valid steps found in CSV file")
        return nil
      end

      parsed_data = {
        title: title,
        description: description,
        steps: steps
      }

      to_workflow_data(parsed_data)
    rescue CSV::MalformedCSVError => e
      add_error("Invalid CSV format: #{e.message}")
      nil
    rescue StandardError => e
      add_error("Error parsing CSV: #{e.message}")
      nil
    end

    private

    def parse_csv_row(row, row_number)
      step_type = (row[:type] || row[:step_type] || 'action').to_s.downcase.strip

      # Auto-convert deprecated types
      converted_from = nil
      if %w[decision simple_decision].include?(step_type)
        converted_from = step_type
        add_warning("Row #{row_number}: Converting deprecated '#{step_type}' to 'question'")
        step_type = 'question'
      elsif step_type == 'checkpoint'
        converted_from = 'checkpoint'
        add_warning("Row #{row_number}: Converting deprecated 'checkpoint' to 'message'")
        step_type = 'message'
      end

      unless VALID_CSV_TYPES.include?(step_type)
        add_warning("Row #{row_number}: Invalid step type '#{step_type}', defaulting to 'action'")
        step_type = 'action'
      end

      step = {
        id: row[:id] || row[:step_id], # Allow explicit ID in CSV
        type: step_type,
        title: row[:title] || row[:step_title] || "Step #{row_number}",
        description: row[:description] || row[:step_description] || ''
      }

      # Flag steps that were auto-converted from deprecated types
      if converted_from
        step[:_import_converted] = true
        step[:_import_converted_from] = converted_from
      end

      case step_type
      when 'question'
        step[:question] = row[:question] || row[:question_text] || ''
        step[:answer_type] = (row[:answer_type] || row[:answer] || 'text').to_s.downcase
        step[:variable_name] = row[:variable_name] || row[:variable] || ''

        if row[:options]
          step[:options] = parse_options(row[:options])
        end

        # Parse transitions for Graph Mode
        if row[:transitions]
          step[:transitions] = parse_transitions(row[:transitions])
        end

      when 'action'
        step[:instructions] = row[:instructions] || row[:action] || ''
        step[:action_type] = row[:action_type] || ''

        # Parse transitions for Graph Mode
        if row[:transitions]
          step[:transitions] = parse_transitions(row[:transitions])
        end

      when 'sub_flow'
        step[:target_workflow_id] = row[:target_workflow_id] || row[:workflow_id]
        step[:target_workflow_title] = row[:target_workflow_title] || row[:workflow_title]

        if row[:transitions]
          step[:transitions] = parse_transitions(row[:transitions])
        end

      when 'message'
        step[:content] = row[:content] || row[:message] || ''

        if row[:transitions]
          step[:transitions] = parse_transitions(row[:transitions])
        end

      when 'escalate'
        step[:target_type] = row[:target_type] || ''
        step[:target_id] = row[:target_id]
        step[:priority] = row[:priority] || 'normal'
        step[:reason] = row[:reason] || ''

        if row[:transitions]
          step[:transitions] = parse_transitions(row[:transitions])
        end

      when 'resolve'
        step[:resolution_type] = row[:resolution_type] || 'success'
        step[:resolution_notes] = row[:resolution_notes] || row[:notes] || ''
        # Resolve steps don't have transitions (terminal)
      end

      step
    end

    def parse_options(options_string)
      return [] if options_string.blank?

      # Try to parse as JSON first
      begin
        parsed = JSON.parse(options_string)
        return parsed if parsed.is_a?(Array)
      rescue JSON::ParserError
        # Fall through to comma-separated parsing
      end

      # Parse as comma-separated values
      options_string.split(',').map do |opt|
        opt = opt.strip
        if opt.include?(':')
          parts = opt.split(':', 2)
          { label: parts[0].strip, value: parts[1].strip }
        else
          { label: opt, value: opt }
        end
      end
    end

    def parse_branches(branches_string)
      return [] if branches_string.blank?

      # Try to parse as JSON first
      begin
        parsed = JSON.parse(branches_string)
        return parsed if parsed.is_a?(Array)
      rescue JSON::ParserError
        # Fall through to comma-separated parsing
      end

      # Parse as semicolon-separated "condition:path" format
      # Using semicolon because conditions may contain commas
      branches_string.split(';').map do |branch|
        branch = branch.strip
        if branch.include?('->')
          # Format: "condition -> path"
          parts = branch.split('->', 2)
          { condition: parts[0].strip, path: parts[1].strip }
        elsif branch.include?(':')
          parts = branch.split(':', 2)
          { condition: parts[0].strip, path: parts[1].strip }
        else
          { condition: branch, path: '' }
        end
      end
    end

    # Parse transitions column for Graph Mode
    # Supports JSON array or semicolon-separated format:
    #   "uuid1" or "uuid1;uuid2" (simple)
    #   "uuid1:condition1;uuid2:condition2" (with conditions)
    #   "uuid1->label1;uuid2->label2" (with labels)
    #   JSON: [{"target_uuid":"...", "condition":"...", "label":"..."}]
    def parse_transitions(transitions_string)
      return [] if transitions_string.blank?

      # Try to parse as JSON first
      begin
        parsed = JSON.parse(transitions_string)
        if parsed.is_a?(Array)
          return parsed.map do |t|
            {
              'target_uuid' => t['target_uuid'] || t['target'],
              'condition' => t['condition'],
              'label' => t['label']
            }.compact
          end
        end
      rescue JSON::ParserError
        # Fall through to text parsing
      end

      # Parse as semicolon-separated format
      transitions_string.split(';').filter_map do |transition|
        transition = transition.strip
        next nil if transition.blank?

        target_uuid = nil
        condition = nil
        label = nil

        if transition.include?(':') && transition.include?('->')
          # Format: "uuid:condition->label"
          parts = transition.split('->', 2)
          left = parts[0]
          label = parts[1]&.strip
          if left.include?(':')
            uuid_cond = left.split(':', 2)
            target_uuid = uuid_cond[0].strip
            condition = uuid_cond[1].strip
          else
            target_uuid = left.strip
          end
        elsif transition.include?(':')
          # Format: "uuid:condition"
          parts = transition.split(':', 2)
          target_uuid = parts[0].strip
          condition = parts[1].strip
        elsif transition.include?('->')
          # Format: "uuid->label"
          parts = transition.split('->', 2)
          target_uuid = parts[0].strip
          label = parts[1].strip
        else
          # Just target UUID or step title
          target_uuid = transition
        end

        result = { 'target_uuid' => target_uuid }
        result['condition'] = condition if condition.present?
        result['label'] = label if label.present?
        result
      end
    end
  end
end
