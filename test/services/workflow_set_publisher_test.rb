require "test_helper"

class WorkflowSetPublisherTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "setpub-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
  end

  # A workflow that can publish on its own: one Question into a Resolve.
  def resolving_workflow(title, status: "draft")
    wf = Workflow.create!(title: title, user: @user, status: status, graph_mode: true)
    q = Steps::Question.create!(workflow: wf, position: 0, title: "Q", question: "What?",
                                variable_name: "q", answer_type: "text")
    r = Steps::Resolve.create!(workflow: wf, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: q, target_step: r, position: 0)
    wf.update!(start_step: q)
    file_in_global(wf)
  end

  # Adds a sub_flow step that is REACHABLE FROM THE START and does not orphan the
  # Resolve. Both matter: GraphValidator refuses an unreachable step, and it
  # refuses a step with no path to a Resolve. A helper that just appended the
  # sub_flow step would fail these tests for reasons that have nothing to do
  # with set publishing.
  #
  # Result: Question branches to the sub_flow first, and falls back to Resolve.
  # A returning sub_flow then continues to Resolve; a handoff takes none, because
  # it ends the workflow.
  def link(source, target, returns: true)
    question = source.steps.find_by(type: "Steps::Question")
    resolve  = source.steps.find_by(type: "Steps::Resolve")

    step = Steps::SubFlow.create!(workflow: source, position: source.steps.count,
                                  title: "To #{target.title}", sub_flow_workflow_id: target.id,
                                  sub_flow_returns: returns)

    Transition.find_by(step: question, target_step: resolve).update!(position: 1)
    Transition.create!(step: question, target_step: step, position: 0)
    Transition.create!(step: step, target_step: resolve, position: 0) if returns
    step
  end

  test "a workflow with no sub-flows is a closure of one" do
    wf = resolving_workflow("Alone")
    assert_equal [wf.id], WorkflowSetPublisher.closure_for(wf).map(&:id)
  end

  test "the closure follows a chain of drafts" do
    a = resolving_workflow("Chain A")
    b = resolving_workflow("Chain B")
    c = resolving_workflow("Chain C")
    link(a, b)
    link(b, c)

    assert_equal [a.id, b.id, c.id].sort, WorkflowSetPublisher.closure_for(a).map(&:id).sort
  end

  test "the closure terminates on a cycle" do
    a = resolving_workflow("Cycle A")
    b = resolving_workflow("Cycle B")
    link(a, b, returns: false)
    link(b, a, returns: false)

    assert_equal [a.id, b.id].sort, WorkflowSetPublisher.closure_for(a).map(&:id).sort
  end

  test "a published target stops the walk and is not a member" do
    a = resolving_workflow("Root A")
    published = resolving_workflow("Already Live", status: "published")
    behind = resolving_workflow("Behind The Published One")
    link(published, behind)
    link(a, published)

    ids = WorkflowSetPublisher.closure_for(a).map(&:id)
    assert_includes ids, a.id
    assert_not_includes ids, published.id, "a published target already satisfies the rule"
    assert_not_includes ids, behind.id, "and its own targets were checked when it published"
  end
  test "a mutual pair publishes as a set where neither can publish alone" do
    a = resolving_workflow("Pair A")
    b = resolving_workflow("Pair B")
    link(a, b, returns: false)
    link(b, a, returns: false)

    assert_not WorkflowPublisher.publish(a.reload, @user).success?,
               "publishing one alone must still fail — that is the deadlock"

    result = WorkflowSetPublisher.publish(a.reload, @user)

    assert_predicate result, :success?, result.error
    assert_equal %w[published published], [a.reload.status, b.reload.status]
  end

  test "after a successful set publish no published workflow points at a draft" do
    a = resolving_workflow("Inv A")
    b = resolving_workflow("Inv B")
    link(a, b, returns: false)
    link(b, a, returns: false)

    assert_predicate WorkflowSetPublisher.publish(a.reload, @user), :success?

    dangling = Steps::SubFlow.where.not(sub_flow_workflow_id: nil).select do |step|
      step.workflow.published? && Workflow.find_by(id: step.sub_flow_workflow_id)&.draft?
    end
    assert_empty dangling, "the rule's timing moved; the rule did not"
  end

  # The set publisher prefixes the member's title, so Rails' own prefix landed
  # in the middle: "Blank B: Validation failed: Steps Sub-flow step 'Not picked
  # yet' requires a target workflow". The title is the only subject this needs.
  test "a refused set names the member and then the plain reason" do
    a = resolving_workflow("Blank A")
    b = resolving_workflow("Blank B")
    link(a, b, returns: false)
    link(b, a, returns: false)
    untargeted = Steps::SubFlow.create!(workflow: b, position: 9, title: "Not picked yet")
    Transition.create!(step: b.steps.find_by(type: "Steps::Question"), target_step: untargeted, position: 2)
    Transition.create!(step: untargeted, target_step: b.steps.find_by(type: "Steps::Resolve"), position: 0)

    result = WorkflowSetPublisher.publish(a.reload, @user)

    assert_not result.success?
    assert_equal "Blank B: Sub-flow step 'Not picked yet' requires a target workflow", result.error
  end

  # The blank-target check moved from every save to publish; a bundle member
  # still in that state must stop the whole set, not slip through with it.
  test "a member with an untargeted sub-flow refuses the whole set" do
    a = resolving_workflow("Blank A")
    b = resolving_workflow("Blank B")
    link(a, b, returns: false)
    link(b, a, returns: false)
    untargeted = Steps::SubFlow.create!(workflow: b, position: 9, title: "Not picked yet")
    Transition.create!(step: b.steps.find_by(type: "Steps::Question"), target_step: untargeted, position: 2)
    Transition.create!(step: untargeted, target_step: b.steps.find_by(type: "Steps::Resolve"), position: 0)

    result = WorkflowSetPublisher.publish(a.reload, @user)

    assert_not result.success?
    assert_includes result.error, "requires a target workflow"
    assert_equal %w[draft draft], [a.reload.status, b.reload.status]
  end

  test "one invalid member rolls the whole set back" do
    a = resolving_workflow("Roll A")
    b = resolving_workflow("Roll B")
    link(a, b, returns: false)
    link(b, a, returns: false)
    # Deleting B's Resolve does NOT make it unpublishable: its handoff is a legal
    # terminal and seeds escapability. An orphan Action is genuinely invalid —
    # unreachable, and a terminal that is not a Resolve.
    Steps::Action.create!(workflow: b, position: 9, title: "Dead End")

    result = WorkflowSetPublisher.publish(a.reload, @user)

    assert_not result.success?
    assert_equal "draft", a.reload.status, "nothing publishes when one member fails"
    assert_equal "draft", b.reload.status
  end

  test "the failure names the workflow that failed" do
    a = resolving_workflow("Name A")
    b = resolving_workflow("Name B")
    link(a, b, returns: false)
    link(b, a, returns: false)
    # Deleting B's Resolve does NOT make it unpublishable: its handoff is a legal
    # terminal and seeds escapability. An orphan Action is genuinely invalid —
    # unreachable, and a terminal that is not a Resolve.
    Steps::Action.create!(workflow: b, position: 9, title: "Dead End")

    result = WorkflowSetPublisher.publish(a.reload, @user)

    assert_not result.success?
    assert_includes result.error, "Name B"
    assert_equal b.id, result.failed_workflow.id
  end

  test "a member the user cannot edit refuses the whole operation" do
    other = User.create!(
      email: "other-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    a = resolving_workflow("Perm A")
    b = Workflow.create!(title: "Someone Elses Draft", user: other, status: "draft", graph_mode: true)
    r = Steps::Resolve.create!(workflow: b, position: 0, title: "Done", resolution_type: "success")
    b.update!(start_step: r)
    link(a, b, returns: false)

    result = WorkflowSetPublisher.publish(a.reload, @user)

    assert_not result.success?
    assert_includes result.error, "Someone Elses Draft"
    assert_equal "draft", a.reload.status
  end

  test "a set whose members have no audience names every one and publishes nothing" do
    root = resolving_workflow("Root Set")
    middle = resolving_workflow("Middle Set")
    leaf = resolving_workflow("Leaf Set")
    link(root, middle)
    link(middle, leaf)
    [middle, leaf].each { it.group_workflows.delete_all }

    result = WorkflowSetPublisher.publish(root.reload, @user)

    assert_not result.success?
    assert_match(/"Middle Set"/, result.error)
    assert_match(/"Leaf Set"/, result.error)
    assert([root, middle, leaf].all? { it.reload.draft? })
  end
end
