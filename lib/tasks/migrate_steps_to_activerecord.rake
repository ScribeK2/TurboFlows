namespace :steps do
  desc "Migrate workflow steps from JSONB to ActiveRecord Step models"
  task migrate: :environment do
    puts "Starting step migration..."

    # Map JSONB type strings to STI class names
    type_map = {
      "question" => "Steps::Question",
      "action" => "Steps::Action",
      "message" => "Steps::Message",
      "escalate" => "Steps::Escalate",
      "resolve" => "Steps::Resolve",
      "sub_flow" => "Steps::SubFlow"
    }

    migrated = 0
    skipped = 0
    errors = []

    Workflow.find_each do |workflow|
      json_steps = workflow.read_attribute(:steps)
      next if json_steps.blank? || !json_steps.is_a?(Array)

      # Skip if already migrated (has ActiveRecord steps)
      if workflow.workflow_steps.any?
        skipped += 1
        next
      end

      begin
        Workflow.transaction do
          # Phase 1: Create all Step records (need IDs for transitions)
          step_records = {}

          json_steps.each_with_index do |step_hash, index|
            next unless step_hash.is_a?(Hash)

            step_type = step_hash["type"]
            sti_type = type_map[step_type]
            next unless sti_type

            attrs = {
              workflow: workflow,
              type: sti_type,
              uuid: step_hash["id"] || SecureRandom.uuid,
              title: step_hash["title"],
              position: index
            }

            # Type-specific attributes
            case step_type
            when "question"
              attrs[:question] = step_hash["question"]
              attrs[:answer_type] = step_hash["answer_type"]
              attrs[:variable_name] = step_hash["variable_name"]
              attrs[:options] = step_hash["options"]
            when "action"
              attrs[:can_resolve] = step_hash["can_resolve"] || false
              attrs[:action_type] = step_hash["action_type"]
              attrs[:output_fields] = step_hash["output_fields"]
              attrs[:jumps] = step_hash["jumps"]
            when "message"
              attrs[:can_resolve] = step_hash["can_resolve"] || false
              attrs[:jumps] = step_hash["jumps"]
            when "escalate"
              attrs[:target_type] = step_hash["target_type"]
              attrs[:target_value] = step_hash["target_value"]
              attrs[:priority] = step_hash["priority"]
              attrs[:reason_required] = step_hash["reason_required"] || false
            when "resolve"
              attrs[:resolution_type] = step_hash["resolution_type"]
              attrs[:resolution_code] = step_hash["resolution_code"]
              attrs[:notes_required] = step_hash["notes_required"] || false
              attrs[:survey_trigger] = step_hash["survey_trigger"] || false
            when "sub_flow"
              attrs[:sub_flow_workflow_id] = step_hash["target_workflow_id"]
              attrs[:variable_mapping] = step_hash["variable_mapping"]
            end

            step_record = Step.create!(attrs)
            step_records[step_hash["id"]] = step_record

            # Set rich text content (markdown → HTML conversion for existing content)
            case step_type
            when "action"
              if step_hash["instructions"].present?
                step_record.instructions = render_markdown_to_html(step_hash["instructions"])
                step_record.save!
              end
            when "message"
              if step_hash["content"].present?
                step_record.content = render_markdown_to_html(step_hash["content"])
                step_record.save!
              end
            when "escalate"
              if step_hash["notes"].present?
                step_record.notes = render_markdown_to_html(step_hash["notes"])
                step_record.save!
              end
            end
          end

          # Phase 2: Create Transition records
          json_steps.each do |step_hash|
            next unless step_hash.is_a?(Hash) && step_hash["id"].present?

            source_step = step_records[step_hash["id"]]
            next unless source_step

            transitions = step_hash["transitions"] || []
            transitions.each_with_index do |trans, idx|
              next unless trans.is_a?(Hash)

              target_uuid = trans["target_uuid"]
              target_step = step_records[target_uuid]
              next unless target_step

              Transition.create!(
                step: source_step,
                target_step: target_step,
                condition: trans["condition"],
                label: trans["label"],
                position: idx
              )
            end
          end

          # Phase 3: Set start_step_id on workflow
          if workflow.start_node_uuid.present? && step_records[workflow.start_node_uuid]
            workflow.update_column(:start_step_id, step_records[workflow.start_node_uuid].id)
          elsif step_records.values.first
            workflow.update_column(:start_step_id, step_records.values.first.id)
          end

          migrated += 1
        end
      rescue => e
        errors << "Workflow ##{workflow.id} (#{workflow.title}): #{e.message}"
        puts "  ERROR: #{e.message}"
      end
    end

    puts "\nMigration complete:"
    puts "  Migrated: #{migrated}"
    puts "  Skipped (already migrated): #{skipped}"
    puts "  Errors: #{errors.length}"
    errors.each { |e| puts "    - #{e}" }
  end

  private

  def render_markdown_to_html(text)
    return "" if text.blank?

    renderer = Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(hard_wrap: true, link_attributes: { target: "_blank" }),
      autolink: true, tables: true, fenced_code_blocks: true, strikethrough: true
    )
    renderer.render(text)
  rescue => e
    # If Redcarpet is already removed, just wrap plain text in <p> tags
    "<p>#{ERB::Util.html_escape(text)}</p>"
  end
end
