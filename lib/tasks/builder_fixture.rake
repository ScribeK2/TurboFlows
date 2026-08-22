# Dev-only fixtures for verifying the builder's visual states.
#
# Deliberately not a test fixture: these exist to be clicked through in a
# browser and read with getComputedStyle, and putting them in test/fixtures
# would slow every test run for no test-side benefit.
#
#   bin/rails builder_fixture:seed
module BuilderFixture
  TYPES = %w[question action message form escalate sub_flow resolve].freeze
  TITLES = [
    "ZZ Builder Fixture - all types",
    "ZZ Builder Fixture - density",
    "ZZ Builder Fixture - clean"
  ].freeze

  class << self
    def seed(owner)
      Workflow.where(title: TITLES).destroy_all
      [coverage(owner), density(owner), clean(owner)]
    end

    private

    # Every step type, plus the edge cases the builder has to render.
    def coverage(owner)
      wf = Workflow.create!(title: TITLES[0], user: owner,
                            description: "Every step type, plus the edge cases the builder has to render.")

      spine = TYPES.each_with_index.map { |type, i| step(wf, type, i + 1, "#{type.titleize} step") }

      # A branching Question with three outgoing transitions. Distinct targets
      # and conditions, since transitions are unique on [step, target, condition].
      branch = step(wf, "question", 8, "Which issue are you seeing?")
      %w[billing technical other].each_with_index do |answer, i|
        Transition.create!(step: branch, target_step: spine[i + 1], position: i,
                           condition: answer, label: answer.titleize)
      end

      # Long title (truncation) and an untitled step (placeholder rendering).
      step(wf, "action", 9, "A deliberately very long step title that has to truncate somewhere sensible rather than wrapping the row")
      step(wf, "message", 10, nil)
      # No outgoing connections, and a non-Resolve terminal (publish-blocking).
      step(wf, "action", 11, "Orphan - no outgoing connections")
      step(wf, "escalate", 12, "Non-resolve terminal - publish error")

      connect(spine)
      wf.reload
    end

    # Zero issues, so the health panel renders its clean state - the one state
    # a fixture full of deliberate problems can never show.
    def clean(owner)
      wf = Workflow.create!(title: TITLES[2], user: owner,
                            description: "A workflow with no health issues at all.")

      steps = [
        step(wf, "question", 1, "Is the account verified?"),
        step(wf, "action", 2, "Record the outcome"),
        step(wf, "resolve", 3, "Resolved")
      ]

      connect(steps)
      wf.reload
    end

    # 40 steps, for list density and scroll behaviour.
    def density(owner)
      wf = Workflow.create!(title: TITLES[1], user: owner,
                            description: "40 steps, for list density and scroll behaviour.")

      steps = Array.new(39) { |i| step(wf, TYPES[i % TYPES.size], i + 1, "Step #{i + 1} - #{TYPES[i % TYPES.size].titleize}") }
      steps << step(wf, "resolve", 40, "Resolved")

      connect(steps)
      wf.reload
    end

    def connect(steps)
      steps.each_cons(2).with_index { |(from, to), i| Transition.create!(step: from, target_step: to, position: i) }
    end

    def step(workflow, type, position, title)
      attrs = { workflow: workflow, position: position, title: title }
      if type == "question"
        attrs[:question] = title
        attrs[:answer_type] = "yes_no"
      end
      Step.class_for_type(type).create!(**attrs)
    end
  end
end

namespace :builder_fixture do
  desc "Seed the builder verification workflows (dev only)"
  task seed: :environment do
    abort "Refusing to seed outside development." unless Rails.env.development?

    owner = User.first or abort "No users in the database - sign up first."

    BuilderFixture.seed(owner).each do |wf|
      puts "/workflows/#{wf.id}?edit=true  #{wf.title} (#{wf.steps.count} steps)"
    end
  end
end
