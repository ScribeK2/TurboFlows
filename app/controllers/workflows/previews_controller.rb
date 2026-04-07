module Workflows
  class PreviewsController < BaseController
    before_action :ensure_can_manage_workflows!
    before_action :ensure_can_view_workflow!

    # GET /workflows/:workflow_id/preview
    def show
      step_data = parse_step_from_params
      step_index = params[:step_index].to_i

      sample_variables = @workflow.sample_variables_for_preview

      render partial: "workflows/preview_frame",
             locals: { step: step_data, index: step_index, sample_variables: sample_variables },
             formats: [:html]
    end

    private

    def parse_step_from_params
      step_params = params[:step] || {}

      options = parse_options(step_params[:options])
      attachments = parse_attachments(step_params[:attachments])

      {
        "type" => step_params[:type] || "",
        "title" => step_params[:title] || "",
        "description" => step_params[:description] || "",
        "question" => step_params[:question] || "",
        "answer_type" => step_params[:answer_type] || "",
        "variable_name" => step_params[:variable_name] || "",
        "options" => options,
        "condition" => step_params[:condition] || "",
        "true_path" => step_params[:true_path] || "",
        "false_path" => step_params[:false_path] || "",
        "action_type" => step_params[:action_type] || "",
        "instructions" => step_params[:instructions] || "",
        "attachments" => attachments,
        "content" => step_params[:content] || "",
        "target_type" => step_params[:target_type] || "",
        "target_value" => step_params[:target_value] || "",
        "priority" => step_params[:priority] || "",
        "reason_required" => step_params[:reason_required] || "",
        "notes" => step_params[:notes] || "",
        "resolution_type" => step_params[:resolution_type] || "",
        "resolution_code" => step_params[:resolution_code] || "",
        "notes_required" => step_params[:notes_required] || "",
        "survey_trigger" => step_params[:survey_trigger] || "",
        "target_workflow_id" => step_params[:target_workflow_id] || ""
      }
    end

    def parse_options(options)
      case options
      when String
        JSON.parse(options)
      when Array
        options.map do |opt|
          if opt.is_a?(Hash)
            { 'label' => opt['label'] || opt[:label], 'value' => opt['value'] || opt[:value] }
          else
            { 'label' => opt.to_s, 'value' => opt.to_s }
          end
        end
      when ActionController::Parameters
        options.values.map do |opt|
          { 'label' => opt['label'] || opt[:label], 'value' => opt['value'] || opt[:value] }
        end
      else
        []
      end
    rescue JSON::ParserError
      []
    end

    def parse_attachments(attachments)
      case attachments
      when String
        JSON.parse(attachments)
      when Array
        attachments.compact
      else
        []
      end
    rescue JSON::ParserError
      []
    end
  end
end
