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

      result = WorkflowImporter.new(current_user, format: format, content: file_content).call

      if result.success?
        @workflow = result.workflow

        if result.incomplete_steps? || result.warnings.any?
          notice_parts = ["Workflow imported successfully in Graph Mode!"]
          notice_parts << "#{result.incomplete_steps_count} incomplete step(s) need attention." if result.incomplete_steps?
          notice_parts << "#{result.warnings.count} warning(s) occurred." if result.warnings.any?
          redirect_to edit_workflow_path(@workflow), notice: notice_parts.join(" ")
        else
          redirect_to workflow_path(@workflow), notice: "Workflow imported successfully in Graph Mode!"
        end
      else
        error_summary = truncate_for_flash(result.errors, max_items: 3)
        redirect_to new_workflow_import_path, alert: "Failed to import workflow: #{error_summary}"
      end
    end

    private

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
