require "test_helper"
require "turbo/broadcastable/test_helper"

module Steps
  class TransitionsControllerTest < ActionDispatch::IntegrationTest
    include ActionView::RecordIdentifier
    include Turbo::Broadcastable::TestHelper

    setup do
      @editor = User.create!(email: "tr-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                             password_confirmation: "password123!", role: "editor")
      @workflow = Workflow.create!(title: "Transitions", user: @editor, graph_mode: true)
      @question = Steps::Question.create!(workflow: @workflow, position: 0, title: "Light green?",
                                          answer_type: "yes_no", variable_name: "light")
      @action = Steps::Action.create!(workflow: @workflow, position: 1, title: "Power cycle")
      @edge = Transition.create!(step: @question, target_step: @action, condition: "light == 'no'", label: "No")
      sign_in @editor
    end

    test "destroy removes the edge and re-renders the list and the connections" do
      assert_difference("Transition.count", -1) do
        delete workflow_step_transition_path(@workflow, @question, @edge),
               headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end

      assert_response :ok
      assert_select "turbo-stream[action='replace'][target='step-list']"
      assert_select "turbo-stream[action='update'][target='#{dom_id(@question, :connections)}']"
    end

    test "destroy of an edge already gone still answers with the list" do
      @edge.destroy
      delete workflow_step_transition_path(@workflow, @question, @edge),
             headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :ok
    end

    test "another step's edge cannot be removed through this step" do
      other = Transition.create!(step: @action, target_step: @question)
      assert_no_difference("Transition.count") do
        delete workflow_step_transition_path(@workflow, @question, other),
               headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
    end

    test "someone who cannot edit the workflow is turned away" do
      sign_out @editor
      stranger = User.create!(email: "st-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                              password_confirmation: "password123!", role: "editor")
      sign_in stranger

      assert_no_difference("Transition.count") do
        delete workflow_step_transition_path(@workflow, @question, @edge)
      end
      assert_redirected_to workflows_path
    end

    test "create points a door at an existing step" do
      resolve = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Done")

      assert_difference("Transition.count", 1) do
        post workflow_step_transitions_path(@workflow, @question),
             params: { target_step_id: resolve.id, label: "Yes", condition: "light == 'yes'" },
             headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end

      assert_response :ok
      assert_equal resolve.id, @question.transitions.find_by!(label: "Yes").target_step_id
      assert_select "turbo-stream[action='update'][target='#{dom_id(@question, :connections)}']"
    end

    test "update retargets one edge" do
      resolve = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Done")

      patch workflow_step_transition_path(@workflow, @question, @edge),
            params: { target_step_id: resolve.id },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :ok
      assert_equal resolve.id, @edge.reload.target_step_id
    end

    test "a target in another workflow is refused and says why" do
      other = Workflow.create!(title: "Other", user: @editor)
      foreign = Steps::Action.create!(workflow: other, position: 0, title: "Foreign")

      assert_no_difference("Transition.count") do
        post workflow_step_transitions_path(@workflow, @question),
             params: { target_step_id: foreign.id, label: "Yes", condition: "light == 'yes'" },
             headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
      assert_response :unprocessable_content
      assert_select "turbo-stream[action='update'][target='#{dom_id(@question, :target_picker_error)}']"
      assert_match "no longer in this workflow", response.body
    end

    # Finding 1: a stale target_step_id used to raise ActiveRecord::RecordNotFound
    # straight out of the action - uncaught, it became a 404 HTML page, which
    # Turbo (the dialog's form has no data-turbo-frame and sits inside
    # #builder-panel) reads as that FRAME's response and wipes the panel to
    # "Content missing". This is the same lookup as the foreign-workflow test
    # above, reached the way a real author hits it: the step WAS in this
    # workflow when the dialog's candidate list was rendered, and is gone now.
    test "create refuses a target step destroyed since the dialog was rendered, and re-streams the options" do
      resolve = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Done")
      stale_id = resolve.id
      resolve.destroy!

      assert_no_difference("Transition.count") do
        post workflow_step_transitions_path(@workflow, @question),
             params: { target_step_id: stale_id, label: "Yes", condition: "light == 'yes'" },
             headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end

      assert_response :unprocessable_content
      assert_select "turbo-stream[action='update'][target='#{dom_id(@question, :target_picker_error)}']"
      assert_select "turbo-stream[action='replace'][target='#{dom_id(@question, :target_picker_options)}']"
      assert_no_match "value=\"#{stale_id}\"", response.body
      assert_match "no longer in this workflow", response.body
    end

    # A pick can also come from the list-level dialog (workflows/_list_target_picker),
    # which a stub chip in the outline opens. It sits in the top layer exactly as
    # the panel's does, so the refusal has to answer inside it too.
    test "a refusal also answers into the list dialog" do
      post workflow_step_transitions_path(@workflow, @question),
           params: { target_step_id: 0, label: "Yes", condition: "light == 'yes'" },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :unprocessable_content
      assert_includes response.body, %(target="list-target-picker-error")
      assert_includes response.body, %(target="list-target-picker-options")
    end

    # Another editor's list dialog is outside #steps-list, which is all the list
    # broadcast replaces, so its candidate list rides along beside it.
    test "a connection broadcasts the list dialog's candidates with the list" do
      resolve = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Done")

      broadcasts = capture_turbo_stream_broadcasts("workflow_#{@workflow.id}") do
        post workflow_step_transitions_path(@workflow, @question),
             params: { target_step_id: resolve.id, label: "Yes", condition: "light == 'yes'" },
             headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end

      assert_includes broadcasts.pluck("target"), "list-target-picker-options"
    end

    test "update refuses a stale target_step_id the same way create does" do
      other_target = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Other target")
      stale_id = other_target.id
      other_target.destroy!

      patch workflow_step_transition_path(@workflow, @question, @edge),
            params: { target_step_id: stale_id },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :unprocessable_content
      assert_select "turbo-stream[action='update'][target='#{dom_id(@question, :target_picker_error)}']"
      assert_select "turbo-stream[action='replace'][target='#{dom_id(@question, :target_picker_options)}']"
      assert_equal @action.id, @edge.reload.target_step_id
    end

    test "update refuses a stale edge id and says the connection is gone" do
      stale_id = @edge.id
      @edge.destroy!

      patch workflow_step_transition_path(@workflow, @question, stale_id),
            params: { target_step_id: @action.id },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :unprocessable_content
      assert_select "turbo-stream[action='update'][target='#{dom_id(@question, :target_picker_error)}']"
      assert_match "no longer exists", response.body
      # The edge is gone, not the target step, so the dialog's own candidate
      # list needs no correction.
      assert_select "turbo-stream[action='replace'][target='#{dom_id(@question, :target_picker_options)}']", false
    end

    test "update refuses a collision and changes nothing" do
      other_target = Steps::Action.create!(workflow: @workflow, position: 2, title: "Other target")
      colliding = Transition.create!(step: @question, target_step: other_target, condition: "light == 'no'")

      patch workflow_step_transition_path(@workflow, @question, colliding),
            params: { target_step_id: @edge.target_step_id },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :unprocessable_content
      assert_match(/<turbo-stream action="update" target="flash"/, response.body)
      assert_match "not saved", response.body
      assert_equal other_target.id, colliding.reload.target_step_id
      # The dialog stays open on a refusal (submitEnded only closes on
      # success), and #flash is invisible behind a showModal() dialog's top
      # layer - the error must also land inside the dialog itself.
      assert_select "turbo-stream[action='update'][target='#{dom_id(@question, :target_picker_error)}']"
      assert_no_match "Validation failed", response.body
    end

    test "create refuses a collision and changes nothing, answering inside the dialog too" do
      resolve = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Done")
      # An extra sharing the wired door's own condition: retargeting the door
      # (through GrowStep.connect, which create uses) collides with it.
      extra = Transition.create!(step: @question, target_step: resolve, condition: "light == 'no'")

      assert_no_difference("Transition.count") do
        post workflow_step_transitions_path(@workflow, @question),
             params: { target_step_id: resolve.id, condition: "light == 'no'" },
             headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end

      assert_response :unprocessable_content
      assert_select "turbo-stream[action='update'][target='flash']"
      assert_select "turbo-stream[action='update'][target='#{dom_id(@question, :target_picker_error)}']"
      assert_no_match "Validation failed", response.body
      assert_equal @action.id, @edge.reload.target_step_id
      assert_equal resolve.id, extra.reload.target_step_id
    end

    test "create is refused for someone who cannot edit the workflow" do
      sign_out @editor
      stranger = User.create!(email: "st2-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                              password_confirmation: "password123!", role: "editor")
      sign_in stranger
      resolve = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Done")

      assert_no_difference("Transition.count") do
        post workflow_step_transitions_path(@workflow, @question),
             params: { target_step_id: resolve.id, label: "Yes", condition: "light == 'yes'" }
      end
      assert_redirected_to workflows_path
    end

    test "update is refused for someone who cannot edit the workflow" do
      sign_out @editor
      stranger = User.create!(email: "st3-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                              password_confirmation: "password123!", role: "editor")
      sign_in stranger
      resolve = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Done")

      patch workflow_step_transition_path(@workflow, @question, @edge),
            params: { target_step_id: resolve.id }
      assert_redirected_to workflows_path
      assert_not_equal resolve.id, @edge.reload.target_step_id
    end
  end
end
