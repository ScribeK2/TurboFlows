require "test_helper"

# Deleting a step used to answer with a bare `turbo_stream.remove` on its own
# row plus a step-count update, so anything that pointed at the deleted step -
# the parent's stub, a later step's number, an open parent panel's Connections
# section - stayed stale until the page reloaded. destroy now answers the way
# a grow does: replace the whole step-list (which already renders the empty
# state when nothing is left), and separately refresh any parent's Connections
# fragment - a stream at a target that is not on the page (no panel open, or a
# panel open on a different step) is a no-op, so there is no need to know
# which panel is open.
class StepsControllerDestroyTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @editor = User.create!(
      email: "editor-destroy-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Destroy WF", user: @editor, graph_mode: true)
    sign_in @editor
  end

  # Question --No--> Action --Next--> Resolve, so deleting the middle step
  # leaves the Question's No door a stub again and renumbers Resolve.
  def branching_workflow
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 0, answer_type: "yes_no", variable_name: "light")
    action = Steps::Action.create!(workflow: @workflow, title: "Power cycle", position: 1)
    resolve = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2, resolution_type: "success")
    Transition.create!(step: question, target_step: action, condition: "light == 'no'", label: "No")
    Transition.create!(step: action, target_step: resolve)
    @workflow.update!(start_step: question)
    [question, action, resolve]
  end

  test "destroy replaces the whole step list and updates the count" do
    _question, action, _resolve = branching_workflow

    assert_difference("Step.count", -1) do
      delete workflow_step_path(@workflow, action), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_select "turbo-stream[action='replace'][target='step-list']"
    assert_select "turbo-stream[action='update'][target='step-count-text']" do
      assert_select "template", text: "2 steps"
    end
  end

  test "the parent row shows a stub for the freed door and no longer mentions the deleted step" do
    question, action, _resolve = branching_workflow

    delete workflow_step_path(@workflow, action), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[action='replace'][target='step-list']" do
      assert_select "template" do
        assert_select "##{dom_id(question, :node)}" do
          assert_select ".builder__door-stub", text: /No → add step/
        end
      end
    end
    assert_no_match(/Power cycle/, response.body)
  end

  test "a later step's ordinal is renumbered" do
    _question, action, resolve = branching_workflow

    delete workflow_step_path(@workflow, action), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[action='replace'][target='step-list']" do
      assert_select "template" do
        assert_select "##{dom_id(resolve)} .builder__step-badge", text: "2"
      end
    end
  end

  test "deleting a step's incoming door refreshes the parent's connections fragment" do
    question, action, _resolve = branching_workflow

    delete workflow_step_path(@workflow, action), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[action='update'][target='#{dom_id(question, :connections)}']" do
      assert_select "template" do
        assert_select ".step-doors__row", text: /No/
      end
    end
    assert_no_match(/Power cycle/, response.body)
  end

  test "deleting the last step yields the empty state and clears the panel" do
    only_step = Steps::Resolve.create!(workflow: @workflow, title: "Only step", position: 0,
                                       resolution_type: "success")
    @workflow.update!(start_step: only_step)

    assert_difference("Step.count", -1) do
      delete workflow_step_path(@workflow, only_step), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_select "turbo-stream[action='replace'][target='step-list']" do
      assert_select "template #builder-empty-state"
    end
    assert_select "turbo-stream[action='update'][target='builder-panel']"
  end

  # A step whose own transition targets itself is its own "parent" by
  # incoming_transitions - captured before the destroy, it must not be
  # streamed a Connections update for a record that is now gone.
  test "a step that loops back to itself does not stream its own connections after being destroyed" do
    _question, action, _resolve = branching_workflow
    Transition.create!(step: action, target_step: action)

    delete workflow_step_path(@workflow, action), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[target='#{dom_id(action, :connections)}']", count: 0
  end
end
