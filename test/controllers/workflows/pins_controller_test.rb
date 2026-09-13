require "test_helper"

class Workflows::PinsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(
      email: "pinner-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @editor = User.create!(
      email: "editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = file_in_global(Workflow.create!(title: "Pinnable Flow", user: @editor))
    sign_in @user
  end

  test "create pins a workflow" do
    assert_difference "UserWorkflowPin.count", 1 do
      post workflow_pin_path(@workflow), as: :turbo_stream
    end
    assert_response :success
    assert @user.pinned_workflows.exists?(@workflow.id)
  end

  test "create returns turbo stream response" do
    post workflow_pin_path(@workflow), as: :turbo_stream
    assert_response :success
    assert_match "turbo-stream", response.content_type
  end

  test "create with HTML fallback redirects" do
    post workflow_pin_path(@workflow)
    assert_response :redirect
  end

  test "create is idempotent for an already-pinned workflow, and the HTML fallback returns to /play" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    assert_no_difference "UserWorkflowPin.count" do
      post workflow_pin_path(@workflow)
    end
    assert_redirected_to play_path
    assert_nil flash[:alert]
  end

  test "a duplicate POST over turbo_stream creates no second pin and streams the pinned toggle" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    assert_no_difference "UserWorkflowPin.count" do
      post workflow_pin_path(@workflow), as: :turbo_stream
    end
    assert_response :success
    assert_includes response.body, "Unpin #{@workflow.title}"
  end

  # Two first pins at the same instant both pass the uniqueness check, and the
  # database's unique index refuses the second INSERT. Reproduced by writing the
  # conflicting pin the moment the check has come back empty. That write lands
  # inside the failed save's savepoint and rolls back with it, so this asserts
  # the answer, not the row; in production the other request's pin is committed.
  test "a pin that loses the race at the unique index still answers as pinned" do
    raced = stage_a_racing_pin(after: 'SELECT 1 AS one FROM "user_workflow_pins"') do
      post workflow_pin_path(@workflow), as: :turbo_stream
    end

    assert raced, "the uniqueness check never ran, so no race was staged"
    assert_response :success
    assert_includes response.body, "Unpin #{@workflow.title}"
  end

  # The other request's pin can also land between looking the pin up and
  # validating it, and then the uniqueness validation refuses the save.
  test "a pin that loses the race at the uniqueness check answers as pinned, not with the model's message" do
    raced = stage_a_racing_pin(after: 'SELECT "user_workflow_pins".* FROM "user_workflow_pins"') do
      post workflow_pin_path(@workflow), as: :turbo_stream
    end

    assert raced, "the pin lookup never ran, so no race was staged"
    assert_response :success
    assert_equal 1, UserWorkflowPin.where(user: @user, workflow: @workflow).count
    assert_includes response.body, "Unpin #{@workflow.title}"
    assert_not_includes response.body, "has already been taken"
  end

  test "a DELETE with no pin succeeds and streams the unpinned toggle" do
    assert_no_difference "UserWorkflowPin.count" do
      delete workflow_pin_path(@workflow), as: :turbo_stream
    end
    assert_response :success
    assert_includes response.body, "Pin #{@workflow.title}"
  end

  test "a pin replaces the workflow's toggle wherever it can appear, and the pinned section" do
    post workflow_pin_path(@workflow), as: :turbo_stream

    assert_select "turbo-stream[action='replace'][target=?]", "pin_recent_workflow_#{@workflow.id}"
    assert_select "turbo-stream[action='replace'][target=?]", "pin_play_workflow_#{@workflow.id}"
    assert_select "turbo-stream[action='replace'][target='pinned-workflows-section']"
    assert_includes response.body, "Unpin #{@workflow.title}"
    # A pinned toggle renders the solid bookmark; nothing else on the page uses
    # the icon library's solid variant, so its fill-based SVG is a fingerprint.
    assert_includes response.body, 'fill="currentColor"'
  end

  test "an unpin replaces the toggles with Pin" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    delete workflow_pin_path(@workflow), as: :turbo_stream

    assert_select "turbo-stream[action='replace'][target=?]", "pin_play_workflow_#{@workflow.id}"
    assert_includes response.body, "Pin #{@workflow.title}"
    assert_not_includes response.body, 'fill="currentColor"'
  end

  test "a refused pin says why in the flash, without leaving the page" do
    UserWorkflowPin::MAX_PINS.times do |i|
      UserWorkflowPin.create!(user: @user, workflow: file_in_global(Workflow.create!(title: "Flow #{i}", user: @editor)))
    end
    extra = file_in_global(Workflow.create!(title: "Over Limit", user: @editor))

    post workflow_pin_path(extra), as: :turbo_stream

    assert_response :unprocessable_content
    assert_select "turbo-stream[action='update'][target='flash']"
    assert_includes response.body, "You can pin up to #{UserWorkflowPin::MAX_PINS} workflows"
  end

  test "create respects pin limit" do
    UserWorkflowPin::MAX_PINS.times do |i|
      wf = file_in_global(Workflow.create!(title: "Flow #{i}", user: @editor))
      UserWorkflowPin.create!(user: @user, workflow: wf)
    end

    extra_wf = file_in_global(Workflow.create!(title: "Over Limit", user: @editor))
    assert_no_difference "UserWorkflowPin.count" do
      post workflow_pin_path(extra_wf)
    end
  end

  test "create returns 404 for invisible workflow" do
    private_wf = Workflow.create!(title: "Private", user: @editor, status: "draft")

    post workflow_pin_path(private_wf), as: :turbo_stream
    assert_response :not_found
  end

  test "destroy unpins a workflow" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    assert_difference "UserWorkflowPin.count", -1 do
      delete workflow_pin_path(@workflow), as: :turbo_stream
    end
    assert_response :success
    assert_not @user.pinned_workflows.exists?(@workflow.id)
  end

  test "destroy returns turbo stream response" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    delete workflow_pin_path(@workflow), as: :turbo_stream
    assert_response :success
    assert_match "turbo-stream", response.content_type
  end

  test "destroy with HTML fallback redirects" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    delete workflow_pin_path(@workflow)
    assert_response :redirect
  end

  test "destroy returns 404 for an invisible workflow" do
    private_wf = Workflow.create!(title: "Private", user: @editor, status: "draft")

    delete workflow_pin_path(private_wf), as: :turbo_stream
    assert_response :not_found
  end

  test "requires authentication" do
    sign_out @user
    post workflow_pin_path(@workflow)
    assert_redirected_to new_user_session_path
  end

  private

  # Stands in for a second request pinning the same workflow: writes that pin
  # the moment the first query starting with `after` has run. Returns whether
  # it ran, so a test can tell a staged race from one that never happened.
  def stage_a_racing_pin(after:, &)
    raced = false
    write_the_other_pin = lambda do |*, payload|
      next if raced || !payload[:sql].start_with?(after)

      raced = true
      UserWorkflowPin.insert_all([{ user_id: @user.id, workflow_id: @workflow.id,
                                    created_at: Time.current, updated_at: Time.current }])
    end

    ActiveSupport::Notifications.subscribed(write_the_other_pin, "sql.active_record", &)
    raced
  end
end
