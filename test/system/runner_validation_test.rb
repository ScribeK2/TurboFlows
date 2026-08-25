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
    visit new_workflow_execution_path(wf)
    click_on "Start Workflow"
    assert_current_step "Verify the caller"

    # A required checkbox must carry the attribute, or the browser lets an
    # unchecked one through and the refusal costs a round trip.
    assert_selector "input[type=checkbox][name='answer[identity_confirmed]'][required]", visible: :all

    fill_in "answer[customer_name]", with: " "
    fill_in "answer[account_ref]", with: "AC-4417"
    check "answer[identity_confirmed]"
    click_on "Submit Form"

    assert_text "Customer name is required"
    assert_current_step "Verify the caller"
    # The refused submit must not cost the user the rest of the form.
    assert_field "answer[account_ref]", with: "AC-4417"
    assert_checked_field "answer[identity_confirmed]"

    # A refused attempt is not a visited step: nothing lands in the trail.
    assert_empty Scenario.where(workflow: wf).last.execution_path
  end
end
