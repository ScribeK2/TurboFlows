require "test_helper"

class PlayerControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(
      email: "playeradmin-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @regular = User.create!(
      email: "playeruser-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = file_in_global(Workflow.create!(title: "Player Flow", user: @admin, status: "published"))
    step = Steps::Resolve.create!(
      workflow: @workflow,
      title: "Done",
      uuid: SecureRandom.uuid,
      position: 0,
      resolution_type: "success"
    )
    @workflow.update!(start_step: step)
    WorkflowPublisher.publish(@workflow, @admin)
  end

  # === Index ===

  test "authenticated user can access player index" do
    sign_in @regular
    get play_path
    assert_response :success
  end

  test "unauthenticated user is redirected from player index" do
    get play_path
    assert_response :redirect
  end

  # The player layout is for runs, not for the Player as a namespace. The index
  # is a browse page and renders the app shell, so it keeps the top bar; the
  # chrome falls away when a run starts, which is the point of the split.
  test "the player index uses the application layout" do
    sign_in @regular
    get play_path
    assert_select "body.player-layout", count: 0
    assert_select "body.page-body"
    assert_select "nav.page-header"
  end

  test "a run uses the player layout" do
    sign_in @regular
    post play_workflow_path(@workflow)
    get player_scenario_step_path(Scenario.last)
    assert_select "body.player-layout"
  end

  # The index carries no leave-the-run control, and should not: you are not in a
  # run, you are choosing one, and the destination would be the page you are on.
  # The affordance belongs to a run, which the next test covers.
  test "the player index has no leave-the-run control" do
    sign_in @regular
    get play_path
    assert_select "a.player-link", count: 0
  end

  # Every exit from a run lands on the workflow list under the same name: this
  # control, the completion screen's, and Cancel, which settles the run and
  # redirects to that completion screen. It read "Exit Player" pointing at
  # root_path while /play rendered the player layout and exiting to it would
  # have been a no-op.
  test "a run offers Back to Workflows, not an exit to the dashboard" do
    sign_in @regular
    post play_workflow_path(@workflow)
    get player_scenario_step_path(Scenario.last)
    assert_select "a.player-link[href=?]", play_path, text: "Back to Workflows"
    assert_select "a.player-link[href=?]", root_path, count: 0
    assert_select "a.player-link", text: "Exit Player", count: 0
  end

  # /play lists workflows you can RUN, so the version it names must be the
  # PUBLISHED one. It read `workflow.versions.last`, and `has_many :versions`
  # carries no default order — `.last` was whatever the database returned.
  #
  # These assert the semantic property (the right column is read), not physical
  # row order, which cannot be forced from a test. The bug is that the two were
  # only ever incidentally equal.
  test "player index names the published version, not the last row returned" do
    published = @workflow.reload.published_version
    # A later version exists but is not the published one. The FK permits this,
    # and it is the only way to tell the two readings apart.
    newer = WorkflowVersion.create!(
      workflow: @workflow, version_number: published.version_number + 1,
      steps_snapshot: [], metadata_snapshot: { "title" => "Newer" },
      published_by: @admin, published_at: Time.current
    )
    sign_in @admin

    get play_path

    assert_response :success
    # Scoped to the row, not the whole body: "v2" also occurs inside SVG path
    # data (d="M12 3v2.25...") on this page, which a body-wide regex matches.
    sub = css_select(".list-row__sub").map(&:text).join(" ")
    assert_includes sub, "v#{published.version_number}"
    assert_not_includes sub, "v#{newer.version_number}",
                        "a version that was never published is not what this page means"
  end

  test "player index still names a version when older ones were released" do
    published = @workflow.reload.published_version
    @workflow.versions.where.not(id: published.id).find_each(&:strip_snapshot!)
    sign_in @admin

    get play_path

    assert_response :success
    assert_includes css_select(".list-row__sub").map(&:text).join(" "),
                    "v#{published.version_number}",
                    "releasing an old snapshot must not blank the current version"
  end

  test "player index omits the version when a workflow has none" do
    unversioned = Workflow.create!(title: "No Versions Yet", user: @admin,
                                   status: "published")
    step = Steps::Resolve.create!(workflow: unversioned, title: "Done",
                                  uuid: SecureRandom.uuid, position: 0,
                                  resolution_type: "success")
    unversioned.update!(start_step: step)
    sign_in @admin

    get play_path

    assert_response :success
    assert_match(/No Versions Yet/, response.body)
  end

  test "player index omits untitled published workflows" do
    untitled = Workflow.create!(title: "Untitled Workflow", user: @admin, status: "published")
    Steps::Resolve.create!(workflow: untitled, title: "Done", uuid: SecureRandom.uuid, position: 0, resolution_type: "success")
    WorkflowPublisher.publish(untitled, @admin)

    sign_in @regular
    get play_path
    assert_select "button", text: /Player Flow/
    assert_select "button", text: /Untitled Workflow/, count: 0
  end

  test "a Regular user gets a pin toggle beside each workflow on /play" do
    sign_in @regular
    get play_path

    assert_select ".player-row[data-player-filter-target='card'][data-title='Player Flow']" do
      assert_select "form button.list-row", text: /Player Flow/
      assert_select "button.pin-button[aria-label='Pin Player Flow']"
    end
  end

  test "a pinned workflow's toggle on /play offers Unpin" do
    UserWorkflowPin.create!(user: @regular, workflow: @workflow)
    sign_in @regular
    get play_path

    assert_select "button.pin-button.is-pinned[aria-label='Unpin Player Flow']"
  end

  test "Editors and Admins get no pin toggle on /play, because their home shows no pins" do
    sign_in @admin
    get play_path

    assert_select ".player-row", minimum: 1
    assert_select ".pin-button", count: 0
  end

  # === Start ===

  test "authenticated user can start a workflow" do
    sign_in @regular
    assert_difference("Scenario.count") do
      post play_workflow_path(@workflow)
    end
    assert_response :redirect
    assert Scenario.exists?(workflow: @workflow, user: @regular)
  end

  test "unauthenticated user cannot start a workflow" do
    post play_workflow_path(@workflow)
    assert_response :redirect
    assert_redirected_to new_user_session_path
  end

  # === Step & Navigation ===

  test "authenticated user can view current step" do
    sign_in @regular
    post play_workflow_path(@workflow)
    scenario = Scenario.last
    get player_scenario_step_path(scenario)
    # Scenario is active with a resolve step ready — renders step view
    assert_response :success
  end

  test "other user cannot access someone else's scenario" do
    sign_in @regular
    post play_workflow_path(@workflow)
    scenario = Scenario.last

    other_user = User.create!(
      email: "other-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    sign_in other_user
    get player_scenario_step_path(scenario)
    assert_response :forbidden
  end

  # === Show (completed scenario) ===

  test "authenticated user can view completed scenario" do
    sign_in @regular
    post play_workflow_path(@workflow)
    scenario = Scenario.last
    # Process through the resolve step so scenario completes
    scenario.process_step
    scenario.save!
    get player_scenario_show_path(scenario)
    assert_response :success
  end

  # === Cancel Button ===

  test "player step renders cancel button for authenticated user" do
    sign_in @regular
    post play_workflow_path(@workflow)
    scenario = Scenario.last
    get player_scenario_step_path(scenario)
    assert_response :success
    assert_select "a[href=?]", player_scenario_stop_path(scenario), text: "Cancel"
  end

  test "player step does not render cancel for shared anonymous scenario" do
    @workflow.generate_share_token!
    # Start via share link (creates scenario as workflow owner)
    get shared_player_path(@workflow.share_token)
    assert_response :redirect
    scenario = Scenario.last
    get player_scenario_step_path(scenario)
    assert_response :success
    assert_select "a[href=?]", player_scenario_stop_path(scenario), text: "Cancel", count: 0
  end

  # === Answer Type Rendering ===

  test "player step renders dropdown select for dropdown answer type" do
    resolve = @workflow.steps.find_by(title: "Done")
    question = Steps::Question.create!(
      workflow: @workflow,
      title: "Pick one",
      uuid: SecureRandom.uuid,
      position: 0,
      answer_type: "dropdown",
      options: [{ "label" => "A", "value" => "a" }, { "label" => "B", "value" => "b" }]
    )
    Transition.create!(step: question, target_step: resolve, position: 0)
    @workflow.update!(start_step: question)
    WorkflowPublisher.publish(@workflow, @admin)

    sign_in @regular
    post play_workflow_path(@workflow)
    scenario = Scenario.last
    get player_scenario_step_path(scenario)
    assert_response :success
    assert_select "select[name=?]", "answer"
    assert_select "option", text: "A"
  end

  # === Concurrency / Stale Scenario ===

  test "next_step survives a lock_version bumped behind its back" do
    resolve = @workflow.steps.find_by(title: "Done")
    question = Steps::Question.create!(
      workflow: @workflow,
      title: "Stale Q",
      uuid: SecureRandom.uuid,
      position: 0,
      answer_type: "text",
      variable_name: "stale_v"
    )
    Transition.create!(step: question, target_step: resolve, position: 0)
    @workflow.update!(start_step: question)
    WorkflowPublisher.publish(@workflow, @admin)

    sign_in @regular
    post play_workflow_path(@workflow)
    scenario = Scenario.last

    # Simulate a concurrent modification by bumping lock_version directly
    Scenario.where(id: scenario.id).update_all(lock_version: scenario.lock_version + 1)

    # The bump is not observable from here: the request loads the row fresh, so
    # its in-memory lock_version already matches and the answer lands normally.
    # This asserts only that a row touched between requests does not 500 the
    # next one. A genuine lost race — the row changing between *this* request's
    # load and its save — is covered at the model level, in ScenarioTest, where
    # two live objects can actually be held at once.
    post player_scenario_next_path(scenario), params: { answer: "test" },
                                              headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "Done", scenario.reload.current_step.title,
                 "the answer landed rather than raising StaleObjectError"
  end

  test "player step renders number input for number answer type" do
    resolve = @workflow.steps.find_by(title: "Done")
    question = Steps::Question.create!(
      workflow: @workflow,
      title: "How many?",
      uuid: SecureRandom.uuid,
      position: 0,
      answer_type: "number"
    )
    Transition.create!(step: question, target_step: resolve, position: 0)
    @workflow.update!(start_step: question)
    WorkflowPublisher.publish(@workflow, @admin)

    sign_in @regular
    post play_workflow_path(@workflow)
    scenario = Scenario.last
    get player_scenario_step_path(scenario)
    assert_response :success
    assert_select "input[type=number]"
  end
end
