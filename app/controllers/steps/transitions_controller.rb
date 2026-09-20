module Steps
  # A single connection, acted on from a door row in the step panel. Answers
  # with the step list (row summaries and stubs change) and the panel's
  # Connections section, whole: the editor beside the doors holds a snapshot,
  # and one still listing a removed connection would save it back.
  class TransitionsController < ApplicationController
    include ActionView::RecordIdentifier

    before_action :set_workflow
    before_action :ensure_can_edit!
    before_action :set_step

    # POST /workflows/:workflow_id/steps/:step_id/transitions
    def create
      GrowStep.connect(workflow: @workflow, from_step: @step, target_step: target_step,
                       label: params[:label], condition: params[:condition])
      render_connections
    rescue GrowStep::Refused => e
      render_refusal(e.message)
    rescue ActiveRecord::RecordInvalid => e
      render_refusal(e.record.errors.full_messages.to_sentence)
    # target_step_id named a step no longer in @workflow - deleted (by this
    # author from the list behind the dialog, or by a collaborator) since the
    # dialog's candidate list was rendered, or never in this workflow at all
    # (a foreign id). Both read the same way from here: the pick was stale.
    rescue ActiveRecord::RecordNotFound
      render_refusal("That step is no longer in this workflow. Pick another.", refresh_options: true)
    end

    # PATCH /workflows/:workflow_id/steps/:step_id/transitions/:id
    def update
      edge = @step.transitions.find_by(id: params[:id])
      return render_refusal("That connection no longer exists. Close this and look again.") unless edge

      edge.update!(target_step: target_step)
      render_connections
    rescue ActiveRecord::RecordInvalid => e
      render_refusal(e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotFound
      render_refusal("That step is no longer in this workflow. Pick another.", refresh_options: true)
    end

    # DELETE /workflows/:workflow_id/steps/:step_id/transitions/:id
    def destroy
      @step.transitions.find_by(id: params[:id])&.destroy
      render_connections
    end

    private

    def target_step
      @workflow.steps.find(params.require(:target_step_id))
    end

    # showModal() puts the target-picker dialog in the browser's top layer,
    # so #flash - fixed position, an ordinary stacking context - renders
    # BEHIND it regardless of z-index: an author with the dialog open would
    # never see a refusal answered only there. This answers inside the
    # dialog too. A Turbo Stream aimed at a target not on the page is a
    # no-op, so this doesn't need to know whether a dialog is even open, or
    # exists for this step at all (a Resolve or handoff source has none).
    #
    # turbo_stream.update marks a plain String content html_safe WITHOUT
    # escaping it first (Turbo::Streams::ActionHelper builds the template
    # with `template.to_s.html_safe`, not an auto-escaping `<%= %>`), so the
    # message is escaped by hand here - a step title or condition value
    # containing `<` or `&` would otherwise land in the page as raw markup.
    #
    # refresh_options: a stale target_step_id means the candidate list itself
    # named a step that is no longer there - re-stream it (never the whole
    # dialog; replacing the <dialog> element closes it, losing the message
    # this same response just wrote into it) so the dialog corrects itself
    # rather than offering the same dead pick again.
    def render_refusal(message, refresh_options: false)
      flash.now[:alert] = "That connection was not saved: #{message}"
      streams = [
        turbo_stream.update("flash", partial: "shared/flash_messages"),
        turbo_stream.update(dom_id(@step, :target_picker_error), ERB::Util.html_escape(message))
      ]
      if refresh_options
        streams << turbo_stream.replace(dom_id(@step, :target_picker_options),
                                        partial: "steps/target_picker_options",
                                        locals: { step: @step, workflow: @workflow })
      end
      render turbo_stream: streams, status: :unprocessable_content
    end

    def set_workflow
      @workflow = Workflow.find(params[:workflow_id])
    end

    def set_step
      @step = @workflow.steps.find(params[:step_id])
    end

    def ensure_can_edit!
      return if @workflow.can_be_edited_by?(current_user)

      redirect_to workflows_path, alert: "You don't have permission to edit this workflow."
    end

    def render_connections
      @step.reload
      steps = @workflow.steps.ordered.includes(transitions: :target_step)

      render turbo_stream: [
        turbo_stream.replace("step-list", partial: "workflows/step_list",
                                          locals: { workflow: @workflow, steps: steps }),
        turbo_stream.update(dom_id(@step, :connections), partial: "steps/connections",
                                                         locals: { step: @step, workflow: @workflow }),
        # The dialog's own list is rendered with the panel, so a step grown
        # after it opened is missing until this refreshes it. This never fights
        # the JS-side close: turbo:submit-end (which closes the dialog on a
        # successful submit) fires before this stream is applied to the DOM -
        # StreamObserver's response handling is async, requestFinished's
        # dispatch is not - so by the time this replace lands the dialog is
        # already closed, and it stays closed (the fresh copy carries no
        # `open` attribute).
        turbo_stream.replace(dom_id(@step, :target_picker), partial: "steps/target_picker",
                                                            locals: { step: @step, workflow: @workflow })
      ]

      Turbo::StreamsChannel.broadcast_update_to(
        "workflow_#{@workflow.id}",
        target: "steps-list",
        partial: "workflows/steps_list_items",
        locals: { workflow: @workflow, steps: steps }
      )
      broadcast_connections
    end

    # The streams above answer the editor who acted. Another editor with this
    # same step's panel open was watching only the list broadcast, so their doors
    # list and candidate list stayed stale until they saved or reopened the
    # panel.
    #
    # The acting editor receives these too - nothing here identifies a sender -
    # and that is fine: their fragment is identical to the one they just
    # rendered. What must NOT be overwritten is an editor mid-edit in the
    # connections editor, which holds rows typed and not yet saved. The browser
    # decides that, in step_transitions#declineWhileDirty, because only the
    # browser knows what is unsaved.
    def broadcast_connections
      Turbo::StreamsChannel.broadcast_update_to(
        "workflow_#{@workflow.id}",
        target: dom_id(@step, :connections),
        partial: "steps/connections",
        locals: { step: @step, workflow: @workflow }
      )
      # Its own partial precisely so the list can be replaced without closing an
      # open dialog; optionTargetConnected re-runs markGoneOptions and filter.
      Turbo::StreamsChannel.broadcast_replace_to(
        "workflow_#{@workflow.id}",
        target: dom_id(@step, :target_picker_options),
        partial: "steps/target_picker_options",
        locals: { step: @step, workflow: @workflow }
      )
    end
  end
end
