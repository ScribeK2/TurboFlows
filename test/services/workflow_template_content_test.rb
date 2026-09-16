require "test_helper"

# Templates are the builder's answer to "what am I building toward" — they lead
# the empty state, and applying one is the only path that produces a correctly
# wired graph in a single click. That makes two things load-bearing:
#
#   1. A template's branches must actually branch. Until 2026-09-16 every
#      template transition carried a `label` and no `condition`, so
#      StepResolver's default-transition lookup (`condition: [nil, ""]`) matched
#      the first one and every answer took the same path. A manager applying
#      "Guided Decision" and running it went to Path A whatever they clicked.
#   2. A template's steps must carry content. `build_steps_data_from_template`
#      copied type, title and position only, so a template was a skeleton that
#      demonstrated the exact defect — empty bodies — we want authors to avoid.
class WorkflowTemplateContentTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "template-content@example.com", password: "password123456", role: "editor")
    @workflow = Workflow.create!(title: "Template content", user: @user)
  end

  test "every template applies cleanly and is publishable on its graph" do
    template_keys.each do |key|
      workflow = Workflow.create!(title: "Applied #{key}", user: @user)
      apply(key, workflow)

      result = WorkflowHealthCheck.call(workflow)
      assert_equal 0, result.summary[:errors],
                   "#{key} applied with graph errors: #{issue_messages(result)}"
    end
  end

  test "every branching question carries options the agent can pick from" do
    template_keys.each do |key|
      workflow = Workflow.create!(title: "Options #{key}", user: @user)
      apply(key, workflow)

      workflow.steps.where(type: "Steps::Question").find_each do |question|
        next if question.transitions.count < 2

        assert_predicate question.answer_type, :present?,
                         "#{key}: branching question #{question.title.inspect} has no answer_type"
        assert_predicate question.options, :present?,
                         "#{key}: branching question #{question.title.inspect} has no options"
      end
    end
  end

  # The heart of it: a question with N outgoing transitions must route N
  # different ways, not N times to the same place.
  test "answering a branching question takes each answer to a different step" do
    template_keys.each do |key|
      workflow = Workflow.create!(title: "Branching #{key}", user: @user)
      apply(key, workflow)
      resolver = StepResolver.new(workflow)

      workflow.steps.where(type: "Steps::Question").find_each do |question|
        next if question.transitions.count < 2

        destinations = question.options.map do |option|
          results = { question.variable_name.to_s => option["value"] }
          resolver.resolve_next(question, results)&.id
        end

        assert_equal destinations.uniq.size, destinations.size,
                     "#{key}: #{question.title.inspect} sent two different answers to the " \
                     "same step — #{destinations.inspect}"
        assert_not_includes destinations, nil,
                            "#{key}: #{question.title.inspect} had an answer that resolved nowhere"
      end
    end
  end

  test "no applied template step is left with an empty body" do
    template_keys.each do |key|
      workflow = Workflow.create!(title: "Bodies #{key}", user: @user)
      apply(key, workflow)

      workflow.steps.each do |step|
        case step
        when Steps::Question
          assert_predicate step.question.to_s.strip, :present?,
                           "#{key}: question #{step.title.inspect} has no question text"
        when Steps::Message
          assert_predicate step.content.to_s.strip, :present?,
                           "#{key}: message #{step.title.inspect} has no body"
        when Steps::Action
          assert_predicate step.instructions.to_s.strip, :present?,
                           "#{key}: action #{step.title.inspect} has no instructions"
        when Steps::Escalate
          assert_predicate step.target_type.to_s.strip, :present?,
                           "#{key}: escalate #{step.title.inspect} has no target_type"
        end
      end
    end
  end

  private

  # Not `WorkflowTemplate.keys.each` — RuboCop's Style/HashEachMethods rewrites
  # that to `each_key`, which WorkflowTemplate does not have.
  def template_keys
    WorkflowTemplate.keys
  end

  def apply(key, workflow)
    template = WorkflowTemplate.find(key)
    controller = StepsController.new
    steps_data, first_uuid = controller.send(:build_steps_data_from_template, template)
    StepBuilder.call(workflow, steps_data, start_node_uuid: first_uuid, replace: true)
    workflow.reload
  end

  def issue_messages(result)
    result.issues.values.flatten.pluck(:message).join("; ")
  end
end
