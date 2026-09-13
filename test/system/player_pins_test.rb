require "application_system_test_case"

# Pinning lives on /play because it is the only page a CSR browses (spec
# 2026-09-13). What only a browser can show: the toggle updates in place, a
# search hides it with its row, and a refused pin reports without leaving.
class PlayerPinsTest < ApplicationSystemTestCase
  setup do
    @editor = User.create!(email: "wf-system-test-editor-#{SecureRandom.hex(4)}@example.com",
                           password: "password123!", password_confirmation: "password123!", role: "editor")
    @csr = User.create!(email: "wf-system-test-csr-#{SecureRandom.hex(4)}@example.com",
                        password: "password123!", password_confirmation: "password123!")
    # In a group of their own. System tests commit, so joinable groups left by
    # other tests would otherwise send a groupless CSR from / to /welcome.
    UserGroup.create!(user: @csr, group: Group.create!(name: "wf-system-test-group-#{SecureRandom.hex(4)}"))
    @alpha = runnable_workflow("Alpha Flow #{SecureRandom.hex(2)}")
    @beta = runnable_workflow("Beta Flow #{SecureRandom.hex(2)}")
    sign_in_as @csr
  end

  teardown do
    Group.where("name LIKE ?", "wf-system-test-group-%").destroy_all
  end

  test "a CSR pins from /play, a search hides the toggle with its row, and home lists the pin" do
    visit play_path

    # By aria-label through CSS: click_button matches it only when
    # Capybara.enable_aria_label is set, and the toggle has no visible text.
    find("button[aria-label='Pin #{@alpha.title}']").click
    assert_selector "button[aria-label='Unpin #{@alpha.title}']", wait: 5

    # `set` types into the element; `fill_in` on an element looks for a field inside it.
    find("input[aria-label='Search workflows']").set(@beta.title)
    assert_no_selector "button[aria-label='Unpin #{@alpha.title}']"
    assert_selector "button[aria-label='Pin #{@beta.title}']"

    visit root_path
    within("#pinned-workflows-section") { assert_text @alpha.title }
  end

  test "a ninth pin is refused on /play without leaving it" do
    UserWorkflowPin::MAX_PINS.times do |i|
      UserWorkflowPin.create!(user: @csr, workflow: runnable_workflow("Pinned #{i} #{SecureRandom.hex(2)}"))
    end

    visit play_path
    # By aria-label through CSS: click_button matches it only when
    # Capybara.enable_aria_label is set, and the toggle has no visible text.
    find("button[aria-label='Pin #{@alpha.title}']").click

    assert_text "You can pin up to #{UserWorkflowPin::MAX_PINS} workflows", wait: 5
    assert_current_path play_path
    assert_selector "button[aria-label='Pin #{@alpha.title}']"
  end

  private

  def runnable_workflow(title)
    workflow = file_in_global(Workflow.create!(title:, user: @editor))
    step = Steps::Resolve.create!(workflow:, title: "Done", position: 0, resolution_type: "success")
    workflow.update!(start_step: step)
    workflow
  end
end
