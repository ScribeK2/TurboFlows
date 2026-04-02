module Workflows
  class ExportsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_workflow
    before_action :ensure_can_view_workflow!

    # GET /workflows/:workflow_id/export
    def show
      steps_data = serialize_ar_steps_for_export(@workflow)
      start_uuid = @workflow.start_step&.uuid || @workflow.steps.first&.uuid

      export_data = {
        title: @workflow.title,
        description: @workflow.description_text || "",
        graph_mode: true,
        start_node_uuid: start_uuid,
        steps: steps_data,
        exported_at: Time.current.iso8601,
        export_version: "2.0"
      }

      send_data export_data.to_json,
                filename: "#{@workflow.title.parameterize}.json",
                type: "application/json"
    end

    # GET /workflows/:workflow_id/export/pdf
    def pdf
      require "prawn"

      pdf = Prawn::Document.new
      pdf.text @workflow.title, size: 24, style: :bold
      pdf.move_down 10
      pdf.text @workflow.description_text, size: 12 if @workflow.description_text.present?
      pdf.move_down 10

      pdf.text "Mode: Graph Mode", size: 10, style: :italic
      pdf.move_down 20

      export_pdf_ar_steps(pdf) if @workflow.steps.any?

      send_data pdf.render, filename: "#{@workflow.title.parameterize}.pdf", type: "application/pdf"
    end

    private

    def set_workflow
      @workflow = Workflow.find(params[:workflow_id])
    end

    def ensure_can_view_workflow!
      unless @workflow.can_be_viewed_by?(current_user)
        redirect_to workflows_path, alert: "You don't have permission to view this workflow."
      end
    end

    def serialize_ar_steps_for_export(workflow)
      StepSerializer.call(workflow)
    end

    def export_pdf_ar_steps(pdf)
      @workflow.steps.includes(:transitions).each_with_index do |step, index|
        step_type = step.type.demodulize.capitalize
        pdf.text "#{index + 1}. #{step.title} [#{step_type}]", size: 14, style: :bold

        case step
        when Steps::Question
          pdf.text "Question: #{step.question}", size: 10 if step.question.present?
          pdf.text "Variable: #{step.variable_name}", size: 9, style: :italic if step.variable_name.present?
        when Steps::Action
          pdf.text "Instructions: #{step.instructions&.to_plain_text}", size: 10 if step.instructions.present?
        when Steps::Message
          pdf.text "Message: #{step.content&.to_plain_text}", size: 10 if step.content.present?
        when Steps::Escalate
          pdf.text "Escalate to: #{step.target_type}", size: 10 if step.target_type.present?
          pdf.text "Priority: #{step.priority}", size: 10 if step.priority.present?
        when Steps::Resolve
          pdf.text "Resolution: #{step.resolution_type}", size: 10 if step.resolution_type.present?
        end

        if step.transitions.any?
          pdf.text "Transitions:", size: 10, style: :bold
          step.transitions.each do |transition|
            target_name = transition.target_step&.title || transition.target_step_id.to_s
            condition_text = transition.condition.present? ? " (if #{transition.condition})" : ""
            pdf.text "  -> #{target_name}#{condition_text}", size: 9
          end
        end

        pdf.move_down 10
      end
    end
  end
end
