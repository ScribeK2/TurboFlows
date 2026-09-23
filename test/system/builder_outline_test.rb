require "application_system_test_case"

# The step list is an outline of the graph. These drive it the way an author
# does and read the page.
class BuilderOutlineTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier

  setup do
    @user = User.create!(email: "outline-sys-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Modem light", user: @user, status: "draft")
    sign_in_as @user
  end

  teardown do
    User.where("email LIKE ?", "outline-sys-%").destroy_all
  end

  # Yes → Working, No → Power cycle → Did it come back? (Yes → Working, No → Escalate)
  def toy_graph
    @q1 = Steps::Question.create!(workflow: @workflow, title: "Power light green?", position: 0, answer_type: "yes_no", variable_name: "light")
    @working = Steps::Resolve.create!(workflow: @workflow, title: "Working", position: 1)
    @cycle = Steps::Action.create!(workflow: @workflow, title: "Power cycle", position: 2)
    @q2 = Steps::Question.create!(workflow: @workflow, title: "Did it come back?", position: 3, answer_type: "yes_no", variable_name: "back")
    @escalate = Steps::Escalate.create!(workflow: @workflow, title: "Escalate to tier 2", position: 4)
    Transition.create!(step: @q1, target_step: @working, condition: "light == 'yes'", position: 0)
    Transition.create!(step: @q1, target_step: @cycle, condition: "light == 'no'", position: 1)
    Transition.create!(step: @cycle, target_step: @q2)
    Transition.create!(step: @q2, target_step: @working, condition: "back == 'yes'", position: 0)
    Transition.create!(step: @q2, target_step: @escalate, condition: "back == 'no'", position: 1)
    @workflow.update_columns(start_step_id: @q1.id)
  end

  test "the step I add after No sits after the question, and Yes stays a stub on it" do
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5

    click_on "Add unconnected step"
    pick_type "Question"
    assert_selector STEP_ROW, count: 1
    assert_panel_settled
    fill_in "step[title]", with: "Power light green?"
    question = @workflow.steps.reload.first

    within(node_for(question)) { click_on "No → add step" }
    pick_type "Action"
    assert_selector STEP_ROW, count: 2, wait: 5
    assert_panel_settled

    action = @workflow.steps.reload.find_by(type: "Steps::Action")
    assert_selector "#steps-list[role='tree']"
    assert_selector "#{STEP_NODE}[data-node-uuid='#{question.uuid}'] + #{STEP_NODE}[data-node-uuid='#{action.uuid}']"
    within(node_for(question)) { assert_selector ".builder__door-stub", text: "Yes → add step" }
    assert_equal "1", node_for(question)["aria-level"]
    assert_equal "1", node_for(action)["aria-level"]
  end

  test "a merged step renders once; the other door is a jump that names it and opens it" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5

    within(node_for(@q1)) do
      assert_selector ".builder__outline-jump", text: "Yes → Working · step 4"
      assert_no_text "below"
    end
    within(node_for(@q2)) { assert_selector "#{STEP_NODE}[data-node-uuid='#{@working.uuid}']" }
    assert_equal "2", node_for(@working)["aria-level"]

    within(node_for(@q1)) { find(".builder__outline-jump").click }
    assert_selector "turbo-frame#builder-panel form", wait: 5
    assert_panel_settled
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{@working.id}']"
    assert_selector "#{STEP_ROW}[data-step-uuid='#{@working.uuid}'].builder__step--selected"
    assert_no_selector ".builder__outline-jump.builder__step--selected"
    assert_equal "true", node_for(@working)["aria-selected"]
  end

  test "a merged step says how many ways lead in, and names them" do
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5

    ways = find("##{dom_id(@working, :ways_in)}")
    assert_equal "2 ways in", ways.text.strip
    assert_equal "From step 1 · Yes, step 3 · Yes", ways[:title]
    assert_includes node_for(@working)["aria-labelledby"], dom_id(@working, :ways_in)
    assert_no_selector "##{dom_id(@cycle, :ways_in)}"
  end

  test "a renamed step's jump chip follows the rename" do
    # A title save streams only the step's own row; the jump chip naming it
    # sits in another node. StepsController#update re-renders the whole list
    # on a title change from Task 6 on ("A structural save re-renders the
    # whole list"), which removes this skip.
    skip "needs Task 6: a title save re-renders the whole list"
    toy_graph
    visit workflow_path(@workflow, edit: true)
    assert_selector STEP_ROW, count: 5, wait: 5

    open_step(@working)
    fill_in "step[title]", with: "All working"
    within(node_for(@q1)) { assert_selector ".builder__outline-jump", text: /All working/, wait: 5 }
    # The open panel survived the list re-render.
    assert_selector "#builder-panel .builder__panel-body[data-step-id='#{@working.id}']"
  end

  test "view mode reads the stubs and offers no buttons" do
    q = Steps::Question.create!(workflow: @workflow, title: "Q", position: 0, answer_type: "yes_no", variable_name: "q")
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    Transition.create!(step: q, target_step: done, condition: "q == 'no'", position: 0)
    @workflow.update_columns(start_step_id: q.id)

    visit workflow_path(@workflow)
    assert_selector "[data-builder-mode-value='view']", wait: 5
    within(node_for(q)) do
      assert_selector ".builder__door-stub-text", text: "→ nothing yet"
      assert_no_selector ".builder__door-stub", visible: true
    end
  end

  test "steps nothing leads to sit in Unconnected" do
    a = Steps::Action.create!(workflow: @workflow, title: "A", position: 0)
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    lone = Steps::Resolve.create!(workflow: @workflow, title: "Lone", position: 2)
    Transition.create!(step: a, target_step: done)
    @workflow.update_columns(start_step_id: a.id)

    visit workflow_path(@workflow, edit: true)
    # The section heading is text-transform: uppercase, and Capybara reads
    # the rendered text.
    assert_selector ".builder__outline-section", text: /unconnected/i, wait: 5
    assert_selector ".builder__outline-section + #{STEP_NODE}[data-node-uuid='#{lone.uuid}']"
  end
end
