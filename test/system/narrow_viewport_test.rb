require "application_system_test_case"

# At a phone's width (390px) a page header must wrap rather than push the page
# sideways or stack its buttons on its title. The driver's window is shared
# across tests, so each one puts it back.
class NarrowViewportTest < ApplicationSystemTestCase
  PHONE = [390, 844].freeze

  setup do
    @tag = SecureRandom.hex(4)
    @admin = User.create!(email: "wf-system-test-narrow-#{@tag}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "admin")
    @workflow = Workflow.create!(title: "wf-system-test-Password reset for locked accounts", user: @admin)
    sign_in_as @admin
    page.driver.browser.manage.window.resize_to(*PHONE)
  end

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
    Workflow.where("title LIKE ?", "wf-system-test-%").destroy_all
    Group.where("name LIKE ?", "wf-system-test-%").order(id: :desc).each(&:destroy!)
  end

  test "the builder header fits a phone in view and edit mode" do
    { "view" => workflow_path(@workflow), "edit" => workflow_path(@workflow, edit: true) }.each do |mode, path|
      visit path
      assert_selector ".builder__header .builder__title"

      assert_phone_width
      assert_no_horizontal_scroll "builder (#{mode})"
      assert_not overlapping?(".builder__header-left", ".builder__header-actions"),
                 "the #{mode} mode actions sit on top of the title"
    end
  end

  test "Workflows with a nested group selected fits a phone" do
    top = Group.create!(name: "wf-system-test-Customer Experience")
    middle = Group.create!(name: "wf-system-test-Phone Support", parent: top)
    leaf = Group.create!(name: "wf-system-test-Tier 2 Escalations", parent: middle)

    visit workflows_path(group_id: leaf.id)
    assert_selector ".wf-breadcrumb", text: "Tier 2 Escalations"

    assert_phone_width
    assert_no_horizontal_scroll "Workflows with a group selected"
    assert_selector ".wf-page-header__actions", text: "New Workflow"
  end

  test "an open step panel takes the whole width on a phone" do
    step = Steps::Resolve.create!(workflow: @workflow, title: "wf-system-test-All done", position: 0)
    @workflow.update!(start_step: step)

    visit workflow_path(@workflow, edit: true)
    find("#{STEP_ROW}[data-step-uuid='#{step.uuid}']").click
    assert_selector "turbo-frame#builder-panel form", wait: 5

    assert_phone_width
    assert_no_horizontal_scroll "builder with a panel open"
    assert_no_selector ".builder__list", visible: true
    main_width = page.evaluate_script("document.querySelector('.builder__main').getBoundingClientRect().width")
    panel_width = page.evaluate_script("document.querySelector('.builder__panel').getBoundingClientRect().width")
    assert_operator panel_width, :>=, main_width - 1

    find(".builder__panel-close").click
    assert_selector ".builder__list", visible: true
  end

  # Below the 640px breakpoint, .builder__list (and the one type picker inside
  # it) is hidden while a panel is open - but the panel's own "New step"
  # buttons (outside the list entirely) must still reach it. It used to be
  # display:none, which drops the picker from the render tree along with
  # everything else, so it sat at 0x0 with no way to open it.
  test "at 600px with a panel open, the panel's New step reaches a real picker" do
    question = Steps::Question.create!(workflow: @workflow, title: "wf-system-test-Light green?",
                                       question: "Light green?", position: 0, answer_type: "yes_no",
                                       variable_name: "light")
    @workflow.update!(start_step: question)
    page.driver.browser.manage.window.resize_to(600, 900)

    visit workflow_path(@workflow, edit: true)
    find("#{STEP_ROW}[data-step-uuid='#{question.uuid}'] .list-row__title").click
    assert_selector "turbo-frame#builder-panel form", wait: 5

    within "turbo-frame#builder-panel" do
      find(".step-doors__row", text: "No").click_on "New step"
    end

    # The picker enters via @starting-style with a scale() transform, so a
    # rect read in the same tick as opening it is still the scaled-down size.
    assert_eventually(timeout: 5) { picker_rect["width"].to_i > 100 }

    rect = picker_rect
    assert_operator rect["width"], :>, 0, "the picker has no width"
    assert_operator rect["height"], :>, 0, "the picker has no height"
    assert_operator rect["left"], :>=, 0, "the picker sits left of the viewport"
    assert_operator rect["top"], :>=, 0, "the picker sits above the viewport"
    assert_operator rect["right"], :<=, page.evaluate_script("window.innerWidth"),
                    "the picker sits right of the viewport"
    assert_operator rect["bottom"], :<=, page.evaluate_script("window.innerHeight"),
                    "the picker sits below the viewport"

    within(".builder__type-picker--floating") do
      find(".builder__type-name", text: "Action", exact_text: true).click
    end

    assert_eventually(timeout: 10) { question.transitions.reload.any? }
    edge = question.transitions.sole
    action = @workflow.steps.reload.find_by!(type: "Steps::Action")
    assert_equal [action.id, "No", "light == 'no'"], [edge.target_step_id, edge.label, edge.condition]
  end

  private

  def picker_rect
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector('.builder__type-picker--floating');
        if (!el) return { width: 0, height: 0, left: -1, top: -1, right: 999999, bottom: 999999 };
        const r = el.getBoundingClientRect();
        return { width: r.width, height: r.height, left: r.left, top: r.top, right: r.right, bottom: r.bottom };
      })()
    JS
  end

  def assert_phone_width
    assert_operator page.evaluate_script("window.innerWidth"), :<=, 400, "the window didn't shrink to a phone's width"
  end

  def assert_no_horizontal_scroll(label)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    viewport = page.evaluate_script("window.innerWidth")

    assert_operator width, :<=, viewport, "#{label} scrolls sideways: #{width}px wide in a #{viewport}px window"
  end

  def overlapping?(selector_a, selector_b)
    page.evaluate_script(<<~JS)
      (() => {
        const a = document.querySelector(#{selector_a.to_json}).getBoundingClientRect();
        const b = document.querySelector(#{selector_b.to_json}).getBoundingClientRect();
        return !(a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top);
      })()
    JS
  end
end
