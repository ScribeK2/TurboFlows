require "application_system_test_case"

# Severity in the outline (the 2026-09-24 look): a problem rings the step's
# number and its icon sits beside the title; the left edge belongs to the
# selection alone. It was a red or amber left border that drew a bracket off
# the list's edge, ~1000px from the icon that explained it.
class BuilderNeutralLookSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "wf-system-test-neutral-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "wf-system-test-Neutral look", user: @user, status: "draft")
    # An Action that leads to an Escalate and nothing after it: both rows
    # carry health errors.
    @question = Steps::Question.create!(workflow: @workflow, title: "Light green?", position: 0,
                                        answer_type: "yes_no", variable_name: "light")
    fixed = Steps::Resolve.create!(workflow: @workflow, title: "Fixed", position: 1)
    @cycle = Steps::Action.create!(workflow: @workflow, title: "Power cycle the modem", position: 2)
    @escalate = Steps::Escalate.create!(workflow: @workflow, title: "Escalate to tier 2", position: 3)
    Transition.create!(step: @question, target_step: fixed, condition: "light == 'yes'", position: 0)
    Transition.create!(step: @question, target_step: @cycle, condition: "light == 'no'", position: 1)
    Transition.create!(step: @cycle, target_step: @escalate)
    @workflow.update!(start_step: @question)
    sign_in_as @user
  end

  teardown do
    Workflow.where("title LIKE ?", "wf-system-test-%").destroy_all
  end

  # Mutation checks: put `border-left-color: var(--color-negative)` back on
  # .builder__step.has-error - red on the edge; drop the badge outline - red
  # on the ring; move the warning icon back after the meta in _step_row - red
  # on the distance.
  test "an error rings the number, and its icon sits beside the title" do
    visit workflow_path(@workflow, edit: true)
    # The Escalate row: "Terminal" follows its title, so the icon has to come
    # before it to sit beside the title.
    row = "#{STEP_ROW}[data-step-uuid='#{@escalate.uuid}']"
    assert_selector "#{row}.has-error", wait: 5

    styles = page.evaluate_script(<<~JS)
      (() => {
        const row = document.querySelector("#{row}")
        const probe = document.createElement("span")
        probe.style.color = "var(--color-negative)"
        row.append(probe)
        const negative = getComputedStyle(probe).color
        probe.remove()
        const badge = getComputedStyle(row.querySelector(".builder__step-badge"))
        const title = row.querySelector(".list-row__title").getBoundingClientRect()
        const icon = row.querySelector(".step-warning-icon").getBoundingClientRect()
        return {
          negative,
          edge: getComputedStyle(row).borderLeftColor,
          ring: badge.outlineStyle + " " + badge.outlineColor,
          gap: Math.round(icon.left - title.right)
        }
      })()
    JS

    assert_not_equal styles["negative"], styles["edge"], "the left edge is not the error colour"
    assert_equal "solid #{styles['negative']}", styles["ring"], "the number is ringed in the error colour"
    assert_operator styles["gap"], :<=, 24, "the warning icon sits beside the title (#{styles['gap']}px away)"
  end
end
