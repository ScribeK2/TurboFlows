module Workflows
  class PinsController < ApplicationController
    # Toggles replaced one by one after a pin change: Recently Run rows on the
    # CSR home and the rows of /play. A location the page doesn't have is a
    # no-op. The pinned section's own toggles come back with the section.
    TOGGLE_LOCATIONS = %w[recent play].freeze

    before_action :authenticate_user!
    before_action :set_workflow

    # POST /workflows/:workflow_id/pin
    #
    # Idempotent: a Back-button page can show a stale toggle (Turbo draws a
    # cached snapshot rather than asking again), so a pin already in place is
    # success, not a uniqueness error surfacing as raw model text.
    def create
      pin = current_user.user_workflow_pins.find_or_initialize_by(workflow: @workflow)

      if pin.persisted? || save_pin(pin)
        respond_to do |format|
          format.turbo_stream { render_pin_updates(pinned: true) }
          format.html { redirect_back_or_to play_path }
        end
      else
        refuse(pin.errors.full_messages.first)
      end
    end

    # DELETE /workflows/:workflow_id/pin
    #
    # Idempotent for the same reason as #create: a stale page's Unpin must not
    # 404 when the pin is already gone.
    def destroy
      current_user.user_workflow_pins.find_by(workflow: @workflow)&.destroy

      respond_to do |format|
        format.turbo_stream { render_pin_updates(pinned: false) }
        format.html { redirect_back_or_to play_path }
      end
    end

    private

    def set_workflow
      @workflow = Workflow.visible_to(current_user).find(params[:workflow_id])
    end

    # Two first pins of the same workflow at once. The losing request is refused
    # either by the uniqueness validation (the other pin landed before it
    # checked) or by the unique index (it landed between the check and the
    # INSERT). Either way the workflow ended up pinned, which is what was asked,
    # so it answers as a pin rather than the model's message or a 500. A refusal
    # with no pin behind it, such as the 8-pin limit, is still a refusal.
    def save_pin(pin)
      pin.save || current_user.user_workflow_pins.exists?(workflow: @workflow)
    rescue ActiveRecord::RecordNotUnique
      true
    end

    def render_pin_updates(pinned:)
      streams = [turbo_stream.replace("pinned-workflows-section",
                                      partial: "dashboard/pinned_workflows",
                                      locals: { dashboard: Dashboard::DataLoader.new(current_user) })]
      TOGGLE_LOCATIONS.each do |location|
        streams << turbo_stream.replace(helpers.dom_id(@workflow, "pin_#{location}"),
                                        partial: "workflows/pins/toggle",
                                        locals: { workflow: @workflow, pinned:, location: })
      end
      render turbo_stream: streams
    end

    # A refusal (the 8-pin limit) answers in place through #flash,
    # the application layout's slot for in-page changes (UIGUIDE § Flash), so
    # the CSR stays on the list they were pinning from. The HTML fallback goes
    # to /play: /workflows is closed to a Regular user.
    def refuse(message)
      respond_to do |format|
        format.turbo_stream do
          flash.now[:alert] = message
          render turbo_stream: turbo_stream.update("flash", partial: "shared/flash_messages"),
                 status: :unprocessable_content
        end
        format.html { redirect_back_or_to play_path, alert: message }
      end
    end
  end
end
