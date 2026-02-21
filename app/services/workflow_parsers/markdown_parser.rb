# Markdown Parser for Kizuflow workflow imports
# Updated for Graph Mode support
module WorkflowParsers
  class MarkdownParser < BaseParser
    def parse
      # Parse markdown content
      lines = @file_content.split("\n")

      # Extract title (first H1 or frontmatter)
      title = extract_title(lines)
      description = extract_description(lines)
      steps = extract_steps(lines)

      if title.blank?
        add_warning("No title found, using default")
        title = "Imported Workflow"
      end

      if steps.empty?
        add_error("No steps found in markdown file")
        return nil
      end

      parsed_data = {
        title: title,
        description: description,
        steps: steps
      }

      # Parse and normalize steps
      workflow_data = to_workflow_data(parsed_data)

      # Explicitly resolve step references for markdown
      if workflow_data[:steps].present?
        workflow_data[:steps] = resolve_step_references(workflow_data[:steps])
      end

      workflow_data
    rescue StandardError => e
      add_error("Error parsing Markdown: #{e.message}")
      nil
    end

    private

    # Valid step types for Markdown import
    VALID_MD_TYPES = %w[question action sub_flow message escalate resolve].freeze

    def extract_title(lines)
      # Check for frontmatter title
      if lines.first&.strip == "---"
        lines.each_with_index do |line, index|
          next if index == 0
          break if line.strip == "---"
          if line =~ /^title:\s*(.+)$/i
            return ::Regexp.last_match(1).strip.gsub(/^["']|["']$/, '')
          end
        end
      end

      # Check for H1 title
      lines.each do |line|
        if line =~ /^#\s+(.+)$/
          return ::Regexp.last_match(1).strip
        end
      end

      nil
    end

    def extract_description(lines)
      description_lines = []
      in_frontmatter = false
      found_title = false
      in_description = false

      lines.each_with_index do |line, index|
        stripped = line.strip

        # Handle frontmatter
        if stripped == "---"
          in_frontmatter = !in_frontmatter
          next
        end

        if in_frontmatter
          if stripped =~ /^description:\s*(.+)$/i
            desc = ::Regexp.last_match(1).strip.gsub(/^["']|["']$/, '')
            return desc unless desc.empty?
          end
          next
        end

        # Skip H1 title
        if /^#\s+/.match?(stripped)
          found_title = true
          next
        end

        # Collect description after title and before first step
        if found_title && !stripped.match(/^##\s+Step|^##\s+Steps|^###\s+Step|^\d+\./)
          if /^##\s+(.+)$/.match?(stripped)
            break
          elsif !stripped.empty?
            description_lines << stripped
            in_description = true
          elsif in_description && stripped.empty?
            break
          end
        end
      end

      description_lines.join(" ").strip
    end

    def extract_steps(lines)
      steps = []
      current_step = nil
      in_step = false
      step_index = 0

      lines.each do |line|
        stripped = line.strip

        # Skip frontmatter
        next if stripped == "---"
        next if /^title:|^description:/i.match?(stripped)

        # Detect step headers (## Step X, ### Step X, or numbered list)
        if match = stripped.match(/^##\s+Step\s+(\d+)[:.]?\s*(.+)$/i)
          step_num = match[1]
          step_title_text = match[2].strip
          title = "Step #{step_num}: #{step_title_text}"

          # Save previous step if exists
          if current_step && current_step[:title].present?
            steps << normalize_step(current_step, step_index)
            step_index += 1
          end

          # Start new step
          current_step = create_new_step(title)
          in_step = true
          next
        elsif stripped.match(/^###\s+Step\s+\d+[:.]?\s*(.+)$/i) ||
              stripped.match(/^##\s+(.+)$/) ||
              stripped.match(/^\d+\.\s+\*\*(.+?)\*\*/)

          # Save previous step if exists
          if current_step && current_step[:title].present?
            steps << normalize_step(current_step, step_index)
            step_index += 1
          end

          title = ::Regexp.last_match(1).strip
          current_step = create_new_step(title)
          in_step = true
          next
        end

        # Parse step content
        if in_step && current_step
          parse_step_line(current_step, stripped)
        end
      end

      # Save last step
      if current_step && current_step[:title].present?
        steps << normalize_step(current_step, step_index)
      end

      steps
    end

    def create_new_step(title)
      {
        type: 'action',
        title: title,
        description: '',
        question: '',
        instructions: '',
        action_type: '',
        answer_type: 'text',
        variable_name: '',
        options: [],
        branches: [],
        else_path: '',
        transitions: [],
        # New Graph Mode step fields
        content: '',
        target_type: '',
        target_id: '',
        priority: 'normal',
        reason: '',
        resolution_type: '',
        resolution_notes: '',
        # Sub-flow fields
        target_workflow_title: '',
        target_workflow_id: '',
        variable_mapping: {}
      }
    end

    def parse_step_line(current_step, stripped)
      # Extract type
      if match = stripped.match(/^\*\*Type\*\*:\s*(.+)$/i) || stripped.match(/^Type:\s*(.+)$/i)
        step_type = (match ? match[1] : ::Regexp.last_match(1)).strip.downcase
        # Auto-convert deprecated types
        step_type = 'question' if %w[decision simple_decision].include?(step_type)
        step_type = 'message' if step_type == 'checkpoint'
        current_step[:type] = VALID_MD_TYPES.include?(step_type) ? step_type : 'action'
        return
      end

      # Extract question
      if match = stripped.match(/^\*\*Question\*\*:\s*(.+)$/i) || stripped.match(/^Question:\s*(.+)$/i)
        current_step[:question] = (match ? match[1] : ::Regexp.last_match(1)).strip
        return
      end

      # Extract answer type
      if match = stripped.match(/^\*\*Answer\s+Type\*\*:\s*(.+)$/i) || stripped.match(/^Answer\s+Type:\s*(.+)$/i)
        current_step[:answer_type] = (match ? match[1] : ::Regexp.last_match(1)).strip.downcase
        return
      end

      # Extract variable name
      if match = stripped.match(/^\*\*Variable\*\*:\s*(.+)$/i) || stripped.match(/^Variable:\s*(.+)$/i)
        current_step[:variable_name] = (match ? match[1] : ::Regexp.last_match(1)).strip
        return
      end

      # Extract options (for multiple choice questions)
      # Format: "Options: Yes, No" or "Options: Billing:billing, Technical:technical"
      if match = stripped.match(/^\*\*Options\*\*:\s*(.+)$/i) || stripped.match(/^Options:\s*(.+)$/i)
        options_str = (match ? match[1] : ::Regexp.last_match(1)).strip
        current_step[:options] = parse_markdown_options(options_str)
        return
      end

      # Extract instructions
      if match = stripped.match(/^\*\*Instructions\*\*:\s*(.+)$/i) || stripped.match(/^Instructions:\s*(.+)$/i)
        current_step[:instructions] = (match ? match[1] : ::Regexp.last_match(1)).strip
        return
      end

      # Extract action type (for action steps)
      if match = stripped.match(/^\*\*Action\s+Type\*\*:\s*(.+)$/i) || stripped.match(/^Action\s+Type:\s*(.+)$/i)
        current_step[:action_type] = (match ? match[1] : ::Regexp.last_match(1)).strip
        return
      end

      # Extract condition (for decision steps)
      if match = stripped.match(/^\*\*Condition\*\*:\s*(.+)$/i) || stripped.match(/^Condition:\s*(.+)$/i)
        current_step[:branches] = [{
          condition: (match ? match[1] : ::Regexp.last_match(1)).strip,
          path: ''
        }]
        return
      end

      # Extract If true path
      if match = stripped.match(/^\*\*If\s+true\*\*:\s*(.+)$/i) || stripped.match(/^If\s+true:\s*(.+)$/i)
        path = (match ? match[1] : ::Regexp.last_match(1)).strip
        if current_step[:branches].empty?
          current_step[:branches] = [{ condition: '', path: path }]
        else
          current_step[:branches][0][:path] = path
        end
        return
      end

      # Extract If false path (becomes else_path)
      if match = stripped.match(/^\*\*If\s+false\*\*:\s*(.+)$/i) || stripped.match(/^If\s+false:\s*(.+)$/i)
        current_step[:else_path] = (match ? match[1] : ::Regexp.last_match(1)).strip
        return
      end

      # Extract transitions (Graph Mode)
      # Format: "Transitions: Step 2, Step 3" or "Transitions: uuid1, uuid2"
      if match = stripped.match(/^\*\*Transitions?\*\*:\s*(.+)$/i) || stripped.match(/^Transitions?:\s*(.+)$/i)
        transitions_str = (match ? match[1] : ::Regexp.last_match(1)).strip
        current_step[:transitions] = parse_markdown_transitions(transitions_str)
        return
      end

      # Extract content (for message steps)
      if match = stripped.match(/^\*\*Content\*\*:\s*(.+)$/i) || stripped.match(/^Content:\s*(.+)$/i)
        current_step[:content] = (match ? match[1] : ::Regexp.last_match(1)).strip
        return
      end

      # Extract target type (for escalate steps)
      if match = stripped.match(/^\*\*Target\s+Type\*\*:\s*(.+)$/i) || stripped.match(/^Target\s+Type:\s*(.+)$/i)
        current_step[:target_type] = (match ? match[1] : ::Regexp.last_match(1)).strip.downcase
        return
      end

      # Extract target ID (for escalate steps)
      if match = stripped.match(/^\*\*Target\s+ID\*\*:\s*(.+)$/i) || stripped.match(/^Target\s+ID:\s*(.+)$/i)
        current_step[:target_id] = (match ? match[1] : ::Regexp.last_match(1)).strip
        return
      end

      # Extract priority (for escalate steps)
      if match = stripped.match(/^\*\*Priority\*\*:\s*(.+)$/i) || stripped.match(/^Priority:\s*(.+)$/i)
        current_step[:priority] = (match ? match[1] : ::Regexp.last_match(1)).strip.downcase
        return
      end

      # Extract reason (for escalate steps)
      if match = stripped.match(/^\*\*Reason\*\*:\s*(.+)$/i) || stripped.match(/^Reason:\s*(.+)$/i)
        current_step[:reason] = (match ? match[1] : ::Regexp.last_match(1)).strip
        return
      end

      # Extract resolution type (for resolve steps)
      if match = stripped.match(/^\*\*Resolution\s+Type\*\*:\s*(.+)$/i) || stripped.match(/^Resolution\s+Type:\s*(.+)$/i)
        current_step[:resolution_type] = (match ? match[1] : ::Regexp.last_match(1)).strip.downcase
        return
      end

      # Extract resolution notes (for resolve steps)
      if match = stripped.match(/^\*\*Resolution\s+Notes\*\*:\s*(.+)$/i) || stripped.match(/^Resolution\s+Notes:\s*(.+)$/i)
        current_step[:resolution_notes] = (match ? match[1] : ::Regexp.last_match(1)).strip
        return
      end

      # Extract target workflow title (for sub_flow steps)
      if match = stripped.match(/^\*\*Target\s+Workflow\*\*:\s*(.+)$/i) || stripped.match(/^Target\s+Workflow:\s*(.+)$/i)
        current_step[:target_workflow_title] = (match ? match[1] : ::Regexp.last_match(1)).strip
        return
      end

      # Extract target workflow ID (for sub_flow steps)
      if match = stripped.match(/^\*\*Target\s+Workflow\s+ID\*\*:\s*(.+)$/i) || stripped.match(/^Target\s+Workflow\s+ID:\s*(.+)$/i)
        current_step[:target_workflow_id] = (match ? match[1] : ::Regexp.last_match(1)).strip
        return
      end

      # Extract description (everything else that's not a recognized field)
      if !(stripped.match(/^\*\*|Type:|Question:|Answer|Variable:|Options:|Instructions:|Action\s+Type:|Condition:|If\s+(true|false):|Transitions?:|Content:|Target\s+(Type|ID|Workflow|Workflow\s+ID):|Priority:|Reason:|Resolution/i) ||
             stripped.match(/^##|^###|^\d+\./) ||
             stripped.empty?) && !current_step[:description].include?(stripped)
        current_step[:description] += " #{stripped}"
      end
    end

    # Parse markdown options format
    # Supports: "Yes, No" or "Billing:billing, Technical:technical, Other:other"
    def parse_markdown_options(options_str)
      options_str.split(',').map do |opt|
        opt = opt.strip
        next nil if opt.blank?

        if opt.include?(':')
          parts = opt.split(':', 2)
          { 'label' => parts[0].strip, 'value' => parts[1].strip }
        else
          { 'label' => opt, 'value' => opt.downcase.gsub(/\s+/, '_') }
        end
      end.compact
    end

    # Parse markdown transitions format
    # Supports: "Step 2, Step 3" or "uuid1, uuid2" or "Step 2 (if condition)"
    def parse_markdown_transitions(transitions_str)
      transitions_str.split(',').map do |t|
        t = t.strip
        next nil if t.blank?

        target = t
        condition = nil
        label = nil

        # Check for condition in parentheses: "Step 2 (if condition)"
        if match = t.match(/^(.+?)\s*\(if\s+(.+?)\)$/i)
          target = match[1].strip
          condition = match[2].strip
        elsif match = t.match(/^(.+?)\s*\((.+?)\)$/)
          target = match[1].strip
          label = match[2].strip
        end

        result = { 'target_uuid' => target }
        result['condition'] = condition if condition.present?
        result['label'] = label if label.present?
        result
      end.compact
    end

    def normalize_step(step, index)
      normalized = {
        type: step[:type] || 'action',
        title: step[:title] || "Step #{index + 1}",
        description: step[:description].to_s.gsub(/\s+/, ' ').strip
      }

      # Add type-specific fields
      case normalized[:type]
      when 'question'
        normalized[:question] = step[:question] || ''
        normalized[:answer_type] = step[:answer_type] || 'text'
        normalized[:variable_name] = step[:variable_name] || ''
        normalized[:options] = step[:options] || [] if step[:options].present?
      when 'action'
        normalized[:instructions] = step[:instructions] || ''
        normalized[:action_type] = step[:action_type] || '' if step[:action_type].present?
      when 'sub_flow'
        normalized[:target_workflow_id] = step[:target_workflow_id] if step[:target_workflow_id].present?
        normalized[:target_workflow_title] = step[:target_workflow_title] if step[:target_workflow_title].present?
        normalized[:variable_mapping] = step[:variable_mapping] || {}
      when 'message'
        normalized[:content] = step[:content] || ''
      when 'escalate'
        normalized[:target_type] = step[:target_type] || ''
        normalized[:target_id] = step[:target_id] if step[:target_id].present?
        normalized[:priority] = step[:priority] || 'normal'
        normalized[:reason] = step[:reason] || ''
      when 'resolve'
        normalized[:resolution_type] = step[:resolution_type] || 'success'
        normalized[:resolution_notes] = step[:resolution_notes] || ''
      end

      # Add transitions if present (Graph Mode)
      if step[:transitions].present? && step[:transitions].any?
        normalized[:transitions] = step[:transitions]
      end

      normalized
    end
  end
end
