require "test_helper"

module Steps
  class TransitionsControllerTest < ActionDispatch::IntegrationTest
    include ActionView::RecordIdentifier

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
      assert_response :not_found
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
