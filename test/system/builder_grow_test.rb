require "application_system_test_case"

# Building a small branching workflow the way an author does it: from the step
# they are on, without the Health panel and without binding a step to another in
# a <select>. If the No answer ever needs Health to attach it, this project was
# not implemented.
class BuilderGrowTest < ApplicationSystemTestCase
  STEP_ROW = "[role='listitem'][data-step-uuid]".freeze

  setup do
    @user = User.create!(email: "grow-sys-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Modem light", user: @user, status: "draft")
    sign_in_as @user
  end

  # System tests commit their records, so a user made here outlives the test.
  teardown do
    User.where("email LIKE ?", "grow-sys-%").destroy_all
  end

  test "a branching flow grows from its rows" do
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5

    click_on "Add a step"
    pick_type "Question"
    assert_selector STEP_ROW, count: 1
    assert_selector "input[name='step[answer_type]'][value='yes_no']:checked", visible: :all, wait: 5

    question = @workflow.steps.reload.sole
    within(row(question)) { click_on "No → add step" }
    pick_type "Action"
    assert_selector STEP_ROW, count: 2

    action = @workflow.steps.reload.find_by!(type: "Steps::Action")
    edge = question.transitions.reload.sole
    assert_equal [action.id, "No", "untitled_question == 'no'"], [edge.target_step_id, edge.label, edge.condition]
    assert_operator action.position, :>, question.position

    # The panel is open on the new Action; the Question's Yes stub is still on its row.
    within(row(question)) { assert_selector ".builder__door-stub", text: "Yes → add step" }

    within(row(action)) { click_on "→ add step" }
    pick_type "Resolve"
    assert_selector STEP_ROW, count: 3
    assert_equal 1, action.transitions.reload.count
    assert_nil action.transitions.first.condition

    assert_no_selector ".builder__door-stub", text: "No →"
  end

  # The autosave race. Changing the answer type marks the panel dirty for two
  # seconds; growing replaces the panel, and the closing panel flushes a save
  # that carries its snapshot of this step's connections - a snapshot taken
  # before the grow. That save used to delete every connection and rebuild from
  # the snapshot, taking the new edge with it.
  #
  # The Question starts as Yes/No so the No door is on screen when the panel
  # opens, and the panel is dirtied through the TITLE: changing the answer type
  # would not do, because the No door it creates is server-rendered and only
  # appears once that autosave has landed - by which time the panel is clean
  # and its closing flush sends nothing.
  test "growing inside the autosave window keeps the new connection" do
    question = Steps::Question.create!(workflow: @workflow, title: "Untitled Question", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    find("#{STEP_ROW}[data-step-uuid='#{question.uuid}']").click
    assert_selector "turbo-frame#builder-panel form", wait: 5

    within "turbo-frame#builder-panel" do
      fill_in "step[title]", with: "Is the light green?"
      find(".step-doors__row", text: "No").click_on "New step"
    end
    pick_type "Action"

    assert_selector STEP_ROW, count: 2
    # The title arriving proves the closing panel's flush was sent. Without this
    # the test passes whenever no flush fires, which is the hollow version.
    assert_eventually(timeout: 10) { question.reload.title == "Is the light green?" }
    assert_equal ["light == 'no'"], question.transitions.reload.map(&:condition)
  end

  # Holds the Ruby doors and the JS presets together by what they do, not by
  # reading one from the other's source.
  test "a connection made with the editor's No preset is read as the No door" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    target = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    find("#{STEP_ROW}[data-step-uuid='#{question.uuid}']").click
    assert_selector "turbo-frame#builder-panel form", wait: 5

    within "turbo-frame#builder-panel" do
      find("summary", text: "Other connections").click
      click_on "Add Connection"
      find("select[data-transition-field='target_uuid']").select "Done"
      find("select[data-condition-preset-target='presetDropdown']").select "No"
    end

    assert_eventually(timeout: 10) { question.transitions.reload.any? }
    no_door = Step::Doors.for(question.reload).doors.find { |door| door.label == "No" }
    assert_equal target, no_door.target_step

    within "turbo-frame#builder-panel" do
      assert_selector ".step-doors__row", text: /No.*Done/m, wait: 5
    end
  end

  # Finding 1. A Yes/No Question has its No door wired. Switching the answer
  # type to Text means Step::Doors no longer claims that edge - it becomes an
  # extra - and the fix is that the whole connections fragment streams back,
  # not just the (now empty) doors list, so "Other connections" shows it at
  # once instead of only after the panel is closed and reopened.
  test "switching answer type reveals a former door in Other connections" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    target = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2)
    Transition.create!(step: question, target_step: target, condition: "light == 'no'", label: "No")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    find("#{STEP_ROW}[data-step-uuid='#{question.uuid}']").click
    assert_selector "turbo-frame#builder-panel form", wait: 5

    within "turbo-frame#builder-panel" do
      find(".choice-card", text: "Text Input").click
      assert_selector "summary", text: /Other connections.*1 connection/m, wait: 5
      label_input = find(".transition-item__label", wait: 5)
      assert_equal "No", label_input.value
    end
  end

  test "a door can be pointed at a step that already exists, and Back does not bring the dialog with it" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    done = Steps::Resolve.create!(workflow: @workflow, title: "All done", position: 2)
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    find("#{STEP_ROW}[data-step-uuid='#{question.uuid}']").click
    assert_selector "turbo-frame#builder-panel form", wait: 5

    within "turbo-frame#builder-panel" do
      find(".step-doors__row", text: "Yes").click_on "Use existing…"
    end
    within "dialog[open]" do
      fill_in "Find a step", with: "done"
      click_on "All done"
    end

    assert_eventually(timeout: 10) { question.transitions.reload.any? }
    edge = question.transitions.sole
    assert_equal [done.id, "light == 'yes'"], [edge.target_step_id, edge.condition]
    within("turbo-frame#builder-panel") { assert_selector ".step-doors__row", text: /Yes.*All done/m }
    assert_no_selector "dialog[open]", visible: :all

    visit workflows_path
    page.go_back
    assert_no_selector "dialog[open]", visible: :all
  end

  test "Change retargets a wired door's own edge instead of adding a second one" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", question: "Light green?",
                                       position: 1, answer_type: "yes_no", variable_name: "light")
    first_target = Steps::Resolve.create!(workflow: @workflow, title: "First", position: 2)
    second_target = Steps::Resolve.create!(workflow: @workflow, title: "Second", position: 3)
    edge = Transition.create!(step: question, target_step: first_target, condition: "light == 'yes'", label: "Yes")
    @workflow.update!(start_step: question)
    visit workflow_path(@workflow, edit: true)
    find("#{STEP_ROW}[data-step-uuid='#{question.uuid}']").click
    assert_selector "turbo-frame#builder-panel form", wait: 5

    within "turbo-frame#builder-panel" do
      find(".step-doors__row", text: "Yes").click_on "Change"
    end
    within "dialog[open]" do
      fill_in "Find a step", with: "second"
      click_on "Second"
    end

    assert_eventually(timeout: 10) { edge.reload.target_step_id == second_target.id }
    assert_equal 1, question.transitions.reload.count
    assert_equal edge.id, question.transitions.sole.id
    within("turbo-frame#builder-panel") { assert_selector ".step-doors__row", text: /Yes.*Second/m }
    assert_no_selector "dialog[open]", visible: :all
  end

  private

  def row(step)
    find("#{STEP_ROW}[data-step-uuid='#{step.uuid}']")
  end

  def pick_type(name)
    within(".builder__type-picker") { find(".builder__type-name", text: name, exact_text: true).click }
  end
end
