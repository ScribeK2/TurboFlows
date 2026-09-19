require "application_system_test_case"

# Server-side step validation, seen from the browser.
#
# Whitespace is the blocked path a browser cannot pre-empt: `required` is
# satisfied by a space, and Steps::Form#validate_responses refuses it because
# " ".blank? is true. No HTML attribute closes that gap, so this case stays
# reachable however the client-side validation is tightened.
#
# The refusal has to be visible. It also has to be free: a blocked attempt
# changes nothing, so the run keeps whatever the user had already typed and
# records no visit to the step.
class RunnerValidationTest < ApplicationSystemTestCase
  test "a form step blocked on a whitespace-only required field says so and keeps the typed values" do
    u = User.create!(email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
                     password: "password123!", password_confirmation: "password123!", role: "editor")
    wf = Workflow.create!(title: "Identity Check", user: u, status: "published")
    form = Steps::Form.create!(
      workflow: wf, title: "Verify the caller", position: 0,
      options: [
        { "name" => "customer_name", "label" => "Customer name",
          "field_type" => "text", "required" => true, "position" => 0 },
        { "name" => "account_ref", "label" => "Account reference",
          "field_type" => "text", "required" => false, "position" => 1 },
        { "name" => "identity_confirmed", "label" => "Confirmed identity",
          "field_type" => "checkbox", "required" => true, "position" => 2 }
      ]
    )
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    Transition.create!(step: form, target_step: done, position: 0)
    wf.update!(start_step: form)

    sign_in_as u
    visit workflow_path(wf)
    click_on "Run Scenario"
    assert_current_step "Verify the caller"

    # A required checkbox must carry the attribute, or the browser lets an
    # unchecked one through and the refusal costs a round trip.
    assert_selector "input[type=checkbox][name='answer[identity_confirmed]'][required]", visible: :all

    fill_in "answer[customer_name]", with: " "
    fill_in "answer[account_ref]", with: "AC-4417"
    check "answer[identity_confirmed]"
    click_on "Submit Form"

    # Under the input it is about, not in a block above it — on a long form the
    # agent should not have to match a sentence back to a field by its label.
    # One retrying assertion rather than find-then-scope: the answer arrives as a
    # Turbo stream that replaces the card, so an element located before the swap
    # goes stale under you.
    assert_selector ".player-form-field:has(input[name='answer[customer_name]']) .form-error",
                    text: "Customer name is required"
    assert_selector "input[name='answer[customer_name]'].is-invalid"
    assert_no_selector "#runner-step-errors"
    assert_current_step "Verify the caller"
    # The refused submit must not cost the user the rest of the form.
    assert_field "answer[account_ref]", with: "AC-4417"
    assert_checked_field "answer[identity_confirmed]"

    # A refused attempt is not a visited step: nothing lands in the trail.
    assert_empty Scenario.where(workflow: wf).last.execution_path
  end

  # The refusal reaches a screen reader, or it reaches nobody who cannot see the
  # red outline. The card is REPLACED by the answer's stream, so the markup
  # carrying the message is a new element every time and cannot be a live region
  # on its own - it is the card's own aria-live region, filled by
  # scenario-step#connect after the card is in the document, that does the work.
  #
  # This asserts the text is routed there. It does NOT assert any screen reader
  # speaks it: that needs a real one, and no test here can stand in for it.
  test "a refused form step announces why, and focuses the field that was refused" do
    blocked_form_scenario

    fill_in "answer[customer_name]", with: " "
    check "answer[identity_confirmed]"
    click_on "Submit Form"

    assert_selector "input[name='answer[customer_name]'].is-invalid", wait: 5

    announced = find("[data-scenario-step-target='announce']", visible: :all).text
    assert_match(/not submitted/i, announced)
    assert_match(/Customer name is required/, announced)

    # Focus goes to the refused field, not the first input: the focus change
    # itself names the field and its invalid state, which is the half a live
    # region cannot carry.
    assert_equal "answer[customer_name]", page.evaluate_script("document.activeElement?.name")
  end

  # A form step arrives with the cursor in its first field, the way a question
  # always has. The scenario-step "input" target is only on question controls,
  # so a form step focused nothing at all and a keyboard agent had to tab in
  # from the top of the page on every one.
  test "a form step arrives with its first field focused" do
    blocked_form_scenario

    assert_equal "answer[customer_name]", page.evaluate_script("document.activeElement?.name")
  end

  # The hidden fields form_with emits come first in the DOM, and focusing one
  # silently does nothing - which would leave focus on <body>, exactly the bug
  # this fixes.
  test "the focused field is a real one, not the form's hidden inputs" do
    blocked_form_scenario

    assert_equal "text", page.evaluate_script("document.activeElement?.type")
  end

  # And a step that was NOT refused still announces itself, which is what the
  # region was built for.
  test "an ordinary step announces its own title, not a refusal" do
    blocked_form_scenario

    announced = find("[data-scenario-step-target='announce']", visible: :all).text
    assert_match(/Verify the caller/, announced)
    assert_no_match(/not submitted/i, announced)
  end

  private

  def blocked_form_scenario
    u = User.create!(email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
                     password: "password123!", password_confirmation: "password123!", role: "editor")
    wf = Workflow.create!(title: "Identity Check", user: u, status: "published")
    form = Steps::Form.create!(
      workflow: wf, title: "Verify the caller", position: 0,
      options: [
        { "name" => "customer_name", "label" => "Customer name",
          "field_type" => "text", "required" => true, "position" => 0 },
        { "name" => "identity_confirmed", "label" => "Confirmed identity",
          "field_type" => "checkbox", "required" => true, "position" => 1 }
      ]
    )
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    Transition.create!(step: form, target_step: done, position: 0)
    wf.update!(start_step: form)

    sign_in_as u
    visit workflow_path(wf)
    click_on "Run Scenario"
    assert_current_step "Verify the caller"
    form
  end
end
