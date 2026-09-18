module Workflows
  class ImportsController < ApplicationController
    before_action :authenticate_user!
    before_action :ensure_editor_or_admin!

    MAX_IMPORT_BYTES = 10.megabytes

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

      if file_content.bytesize > MAX_IMPORT_BYTES
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

      # The upload is capped at 10MB in #create; this round-trips through a
      # hidden form field, so it is fresh user input and needs the same bound.
      # It was re-validated but not re-bounded, and a bundle now fits far more
      # into one payload than a single workflow did.
      if content.bytesize > MAX_IMPORT_BYTES
        redirect_to new_workflow_import_path, alert: "File is too large. Maximum size is 10MB."
        return
      end

      report = StrictImportValidator.new(user: current_user, content:).validate

      return render_report(content, report, :unprocessable_entity) unless report.valid?

      result = WorkflowImporter.new(current_user, format: :json, content:, strict_report: report).call

      if result.success?
        redirect_to import_destination(result), notice: import_summary(result)
      else
        render_report(content, commit_refusal_report(report, result), :unprocessable_content)
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

    # A refusal that only exists at commit, on the same page as one found at
    # preview.
    #
    # StrictImportValidator binds in-bundle sub-flow targets by title but never
    # walks the graph they make, so a cycle or an over-deep chain is reachable
    # only after insert: preview passes, SubflowValidator refuses, the transaction
    # rolls back. That went out as a flash — bottom right, gone in five seconds,
    # three messages cut at 150 characters — and because the same file fails the
    # same way every time, the toast was the only report anyone got. A cycle
    # message naming five workflows runs past 250 characters, so the first one
    # was cut in the middle of the path it existed to show.
    #
    # The messages are already whole on WorkflowImporter::Result; they only
    # needed somewhere to stand. One stable code, no path: the finding is about
    # the set, not a place in the file. The preview's warnings ride along, since
    # they are still true of the file being sent back to whoever wrote it.
    def commit_refusal_report(report, result)
      errors = result.errors.map do |message|
        { path: nil, code: "refused_at_commit", message: message.to_s, value: nil }
      end

      StrictImportValidator::Report.new(errors: errors, warnings: report.warnings,
                                        workflows_data: nil, placements: nil)
    end

    def render_report(content, report, status)
      @content = content
      @report = report
      render :report, status: status
    end

    # Where to land after a successful strict import.
    #
    # One workflow goes to that workflow, as it always has. A set has no single
    # right answer, and picking the first would hide the other four — so it goes
    # to the list, where the whole set is visible and the notice names it.
    def import_destination(result)
      result.multiple? ? workflows_path : workflow_path(result.workflow)
    end

    def import_summary(result)
      return bundle_summary(result) if result.multiple?

      workflow = result.workflow
      parts = ["Imported #{workflow.steps.count} steps as a draft"]
      parts << "in #{workflow.groups.map(&:name).to_sentence}" if workflow.groups.any?
      parts << "tagged #{workflow.tags.map(&:name).to_sentence}" if workflow.tags.any?
      "#{parts.join(', ')}."
    end

    # Counts across the set, and the titles, because after importing five
    # workflows at once "which ones?" is the immediate question.
    def bundle_summary(result)
      workflows = result.workflows
      steps = workflows.sum { |workflow| workflow.steps.count }
      titles = workflows.map(&:title).to_sentence
      "Imported #{workflows.size} workflows (#{steps} steps) as drafts: #{titles}."
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
