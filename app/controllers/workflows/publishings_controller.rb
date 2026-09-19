module Workflows
  class PublishingsController < BaseController
    before_action :ensure_can_edit_workflow!

    # POST /workflows/:workflow_id/publishing
    def create
      members = WorkflowSetPublisher.closure_for(@workflow)

      # Two reasons to stop and show a page first, both preview-then-commit like
      # the strict import:
      #
      #   1. Publishing several workflows from one unqualified button press would
      #      be a surprise. The second POST carries publish_set.
      #   2. The workflow runs but does not say anything useful — an empty
      #      Message body, an Escalate with no destination. Readiness deliberately
      #      does NOT refuse (a hard block gets worked around by typing a space
      #      into the field); it interrupts once and asks. The second POST carries
      #      acknowledge_readiness. This is what a first-time editor never got: he
      #      shipped a workflow he knew was thin and the product congratulated him.
      if needs_confirmation?(members) && !confirmed?
        return redirect_to confirm_workflow_publishing_path(@workflow)
      end

      members.size > 1 ? publish_set : publish_one
    end

    # GET /workflows/:workflow_id/publishing/confirm
    def confirm
      @members = WorkflowSetPublisher.closure_for(@workflow)
      @readiness_issues = readiness_issues
      redirect_to workflow_path(@workflow) unless needs_confirmation?(@members)
    end

    private

    def needs_confirmation?(members)
      return true if members.size > 1

      # Readiness is a "this will run, but it is thin" conversation. If the
      # workflow cannot be published at all, that is the conversation to have
      # instead — the confirmation page says nothing about a broken graph, so
      # asking here would send the author to click "Publish anyway" and only
      # then meet the real refusal.
      readiness_issues.any? && publish_blockers.none?
    end

    def publish_blockers
      health.publish_blockers
    end

    def health
      @health ||= WorkflowHealthCheck.call(@workflow)
    end

    # Either token gets you through: the confirmation page shows both reasons at
    # once, so a reader who has seen it has seen all of it.
    def confirmed?
      params[:publish_set].present? || params[:acknowledge_readiness].present?
    end

    def readiness_issues
      @readiness_issues ||= health.readiness_issues
    end

    def publish_one
      result = WorkflowPublisher.publish(@workflow, current_user, changelog: params[:changelog])

      if result.success?
        redirect_to @workflow, notice: "Workflow published as version #{result.version.version_number}."
      else
        # Back to the builder in edit mode. Redirecting to @workflow dropped
        # `edit=true`, so a failed publish silently swapped the header for
        # Edit/Run Scenario/Export and took the add-step control away — the user is told
        # to fix something and simultaneously loses the tools to fix it.
        redirect_to workflow_path(@workflow, edit: true), alert: "Failed to publish: #{result.error}"
      end
    end

    def publish_set
      result = WorkflowSetPublisher.publish(@workflow, current_user, changelog: params[:changelog])

      if result.success?
        redirect_to @workflow, notice: "Published #{result.workflows.size} workflows together."
      else
        redirect_to workflow_path(@workflow, edit: true), alert: "Failed to publish: #{result.error}"
      end
    end
  end
end
