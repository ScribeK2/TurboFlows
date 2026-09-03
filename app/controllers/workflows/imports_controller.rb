module Workflows
  class ImportsController < ApplicationController
    before_action :authenticate_user!
    before_action :ensure_editor_or_admin!

    # GET /workflows/import
    def new
      # Show import form
    end

    # POST /workflows/import
    def create
      if params[:file].blank?
        redirect_to new_workflow_import_path, alert: "Please select a file to import."
        return
      end

      uploaded_file = params[:file]
      file_content = uploaded_file.read.force_encoding("UTF-8")

      if file_content.bytesize > 10.megabytes
        redirect_to new_workflow_import_path, alert: "File is too large. Maximum size is 10MB."
        return
      end

      format = detect_file_format(uploaded_file.original_filename, uploaded_file.content_type)

      unless format
        redirect_to new_workflow_import_path, alert: "Unsupported file format. Please use JSON, CSV, YAML, or Markdown files."
        return
      end

      return render_strict_report(file_content) if strict_dialect?(format, file_content)

      result = WorkflowImporter.new(current_user, format: format, content: file_content).call

      if result.success?
        @workflow = result.workflow

        if result.incomplete_steps? || result.warnings.any?
          redirect_to edit_workflow_path(@workflow, health: true),
                      notice: "Workflow imported. Review issues in the Health panel."
        else
          redirect_to workflow_path(@workflow), notice: "Workflow imported successfully in Graph Mode!"
        end
      else
        error_summary = truncate_for_flash(result.errors, max_items: 3)
        redirect_to new_workflow_import_path, alert: "Failed to import workflow: #{error_summary}"
      end
    end

    # POST /workflows/import/commit
    #
    # The content makes a round trip through the browser, so it is user input
    # again: re-validate rather than trusting the report that produced the page.
    def commit
      content = params[:content].to_s
      report = StrictImportValidator.new(user: current_user, content:).validate

      return render_report(content, report, :unprocessable_entity) unless report.valid?

      result = WorkflowImporter.new(current_user, format: :json, content:, strict_report: report).call

      if result.success?
        redirect_to workflow_path(result.workflow), notice: import_summary(result)
      else
        redirect_to new_workflow_import_path,
                    alert: "Failed to import workflow: #{truncate_for_flash(result.errors)}"
      end
    end

    private

    def strict_dialect?(format, content)
      format == :json && StrictImportValidator.strict?(content)
    end

    def render_strict_report(content)
      report = StrictImportValidator.new(user: current_user, content:).validate
      render_report(content, report, report.valid? ? :ok : :unprocessable_content)
    end

    def render_report(content, report, status)
      @content = content
      @report = report
      render :report, status: status
    end

    def import_summary(result)
      workflow = result.workflow
      parts = ["Imported #{workflow.steps.count} steps as a draft"]
      parts << "in #{workflow.groups.map(&:name).to_sentence}" if workflow.groups.any?
      parts << "tagged #{workflow.tags.map(&:name).to_sentence}" if workflow.tags.any?
      "#{parts.join(', ')}."
    end

    def detect_file_format(filename, content_type)
      extension = File.extname(filename).downcase

      case extension
      when '.json'
        :json
      when '.csv'
        :csv
      when '.yaml', '.yml'
        :yaml
      when '.md', '.markdown'
        :markdown
      else
        case content_type
        when 'application/json', 'text/json'
          :json
        when 'text/csv', 'application/csv'
          :csv
        when 'text/x-yaml', 'application/x-yaml'
          :yaml
        when 'text/markdown', 'text/x-markdown'
          :markdown
        end
      end
    end

    def truncate_for_flash(messages, max_items: 3, max_length: 500)
      return "" if messages.blank?

      truncated = messages.first(max_items).map { |m| m.to_s.truncate(150) }
      result = truncated.join(", ")

      if messages.length > max_items
        result += " (and #{messages.length - max_items} more...)"
      end

      result.truncate(max_length)
    end
  end
end
