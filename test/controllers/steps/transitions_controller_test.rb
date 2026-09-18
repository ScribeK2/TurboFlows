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
  end
end
