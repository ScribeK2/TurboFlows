# Builds a database shaped like production's on 2026-09-14, for rehearsing a
# deploy against the replica. Run with rails runner on an EMPTY database:
#
#   bin/rails runner /load/seeds/prod_shape.rb      (inside the replica's web container)
#
# Production's counts then: 8 users, 6 groups (Global among them), no group
# memberships, 24 published workflows of ~25 steps with one version each, 20 of
# them filed in a group, 36 tags on 98 taggings, 7 runs and one SMTP setting.
# Content is invented; only the shape is production's.
#
# Written to run on the code as of 44e3c202 (2026-09-11) as well as on main, so
# it only uses what existed then. Production has since been deployed with main.

require_relative "guard"
LoadTestSeedGuard.check!

abort "prod_shape: the database already has users; this seeds an empty database only." if User.exists?

srand(20_260_914)
PASSWORD = "LoadTest!2026".freeze

def make_user(email, role)
  User.create!(email: email, password: PASSWORD, password_confirmation: PASSWORD, role: role)
end

def rich(step, attribute, text)
  step.public_send(:"#{attribute}=", "<p>#{text}</p>")
  step.save!
end

def add_step(workflow, klass, position, attrs = {})
  klass.create!({ workflow: workflow, uuid: SecureRandom.uuid, position: position }.merge(attrs))
end

def seed_link(from, to, position, condition: nil)
  Transition.create!(step: from, target_step: to, position: position, condition: condition)
end

# 25 steps: an intro message, then four segments. Each segment asks a yes/no
# question; yes works through action → message → action → escalate → resolve,
# no moves on to the next segment's question (the last one resolves).
def build_workflow(title, owner)
  workflow = Workflow.create!(title: title, user: owner, status: "draft")
  position = 0
  intro = add_step(workflow, Steps::Message, position, title: "Before you start")
  rich(intro, :content, "Confirm the caller's name and account before continuing.")

  segments = Array.new(4) do |k|
    q = add_step(workflow, Steps::Question, position += 1, title: "Check #{k + 1}", question: "Does check #{k + 1} pass?",
                                                           answer_type: "yes_no")
    a1 = add_step(workflow, Steps::Action, position += 1, title: "Gather details #{k + 1}")
    rich(a1, :instructions, "Ask for the details listed in the knowledge base article for check #{k + 1}.")
    m = add_step(workflow, Steps::Message, position += 1, title: "Explain next steps #{k + 1}")
    rich(m, :content, "Tell the customer what happens next and how long it usually takes.")
    a2 = add_step(workflow, Steps::Action, position += 1, title: "Apply fix #{k + 1}")
    rich(a2, :instructions, "Apply the standard fix, then confirm with the customer.")
    e = add_step(workflow, Steps::Escalate, position += 1, title: "Escalate if unresolved #{k + 1}")
    rich(e, :notes, "Escalate with the ticket number and what was already tried.")
    r = add_step(workflow, Steps::Resolve, position += 1, title: "Resolved #{k + 1}", resolution_type: "success")
    rich(r, :description, "Summarise the resolution in the ticket.")

    seed_link(q, a1, 0, condition: "yes")
    seed_link(a1, m, 0)
    seed_link(m, a2, 0)
    seed_link(a2, e, 0)
    seed_link(e, r, 0)
    { question: q, resolve: r }
  end

  seed_link(intro, segments.first[:question], 0)
  segments.each_cons(2) { |current, following| seed_link(current[:question], following[:question], 1, condition: "no") }
  seed_link(segments.last[:question], segments.last[:resolve], 1, condition: "no")

  workflow.update!(start_step: intro)
  workflow
end

ActiveRecord::Base.transaction do
  admin = make_user("admin@loadtest.local", "admin")
  editors = Array.new(2) { |i| make_user("editor#{i + 1}@loadtest.local", "editor") }
  regulars = Array.new(5) { |i| make_user("csr#{i + 1}@loadtest.local", "user") }
  owners = [admin, *editors]

  global = Group.find_by(name: Group::GLOBAL_NAME, parent_id: nil) || Group.create!(name: Group::GLOBAL_NAME)
  departments = %w[Support Billing Onboarding Escalations Training].map { |name| Group.create!(name: name) }
  audiences = [global, *departments]

  tags = Array.new(36) { |i| Tag.create!(name: "topic-#{i + 1}") }

  workflows = Array.new(24) do |i|
    workflow = build_workflow("Troubleshooting flow #{i + 1}", owners[i % owners.size])
    GroupWorkflow.create!(group: audiences[i % audiences.size], workflow: workflow, is_primary: true)
    result = WorkflowPublisher.publish(workflow, workflow.user)
    raise "publish failed for #{workflow.title}: #{result.error}" unless result.success?

    4.times { |t| Tagging.create!(tag: tags[((i * 4) + t) % tags.size], workflow: workflow) }
    workflow
  end
  # Two more to reach production's 98; workflow 1 already has tags 1–4.
  Tagging.create!(tag: tags[8], workflow: workflows[0])
  Tagging.create!(tag: tags[9], workflow: workflows[0])

  # Production has 24 published workflows but only 20 group filings.
  workflows.last(4).each { |workflow| workflow.group_workflows.destroy_all }

  workflows.first(7).each_with_index do |workflow, i|
    started = (i + 1).days.ago
    path = workflow.steps.order(:position).first(4).map do |step|
      { "step_title" => step.title, "step_type" => step.step_type, "step_uuid" => step.uuid,
        "started_at" => started.iso8601(3) }
    end
    Scenario.create!(workflow: workflow, user: regulars[i % regulars.size], purpose: "live", status: "completed",
                     outcome: "resolved", started_at: started, completed_at: started + 4.minutes,
                     duration_seconds: 240, execution_path: path)
  end

  SmtpSetting.create!(enabled: false)
end

counts = {
  users: User.count, groups: Group.count, user_groups: UserGroup.count, workflows: Workflow.count,
  workflow_versions: WorkflowVersion.count, steps: Step.count, transitions: Transition.count,
  rich_texts: ActionText::RichText.count, group_workflows: GroupWorkflow.count, tags: Tag.count,
  taggings: Tagging.count, scenarios: Scenario.count, smtp_settings: SmtpSetting.count
}
puts "prod_shape seeded: #{counts.map { |k, v| "#{k}=#{v}" }.join(' ')}"
