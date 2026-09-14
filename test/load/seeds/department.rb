# Adds the department on top of prod_shape.rb, for the load test (grill Q20, Q42):
#
#   csr001–csr250   CSRs, 50 in each of the five teams, so / lands on the CSR home
#                   and /play lists their team's workflows plus Global. The test
#                   runs 150; k6 numbers VUs across all its scenarios together,
#                   and department.js maps a CSR VU to csr<VU number>, so there
#                   must be an account for every number up to the total.
#   rush001–rush050 accounts in no group, for the sign-in rush through /welcome
#   mgr01–mgr12     managers: a member AND a manager of their team (AGENTS.md —
#                   a manager in no group is sent to /welcome like anyone else)
#   editor01–05     editors, each a member of a team
#
# plus a workflow with a returning sub-flow and one that hands off, because real
# workflows can't come to this machine and those are the shapes that cost most.
#
#   bin/rails runner /load/seeds/department.rb      (inside the replica's web container)
#
# Every account's password is LoadTest!2026. Accounts are inserted with one
# shared password hash: 217 bcrypt rounds inside a 1.9 GiB VM would measure the
# seed, not the app.

require_relative "guard"
LoadTestSeedGuard.check!

abort "department: run prod_shape.rb first." unless User.exists?(email: "admin@loadtest.local")
abort "department: already seeded." if User.exists?(email: "csr001@loadtest.local")

PASSWORD = "LoadTest!2026".freeze
TEAMS = %w[Support Billing Onboarding Escalations Training].freeze

def insert_users(emails, role)
  now = Time.current
  hash = User.new(password: PASSWORD).encrypted_password
  rows = emails.map { |email| { email: email, encrypted_password: hash, role: role, created_at: now, updated_at: now } }
  User.insert_all!(rows)
  User.where(email: emails).order(:email).to_a
end

def join(users, group)
  now = Time.current
  UserGroup.insert_all!(users.map { |u| { user_id: u.id, group_id: group.id, self_joined: false, created_at: now, updated_at: now } })
end

def add_step(workflow, klass, position, attrs = {})
  klass.create!({ workflow: workflow, uuid: SecureRandom.uuid, position: position }.merge(attrs))
end

def seed_link(from, to, position, condition: nil)
  Transition.create!(step: from, target_step: to, position: position, condition: condition)
end

def publish!(workflow, group)
  GroupWorkflow.create!(group: group, workflow: workflow, is_primary: true)
  result = WorkflowPublisher.publish(workflow, workflow.user)
  raise "publish failed for #{workflow.title}: #{result.error}" unless result.success?
end

ActiveRecord::Base.transaction do
  teams = TEAMS.map { |name| Group.find_by!(name: name, parent_id: nil) }
  global = Group.find_by!(name: Group::GLOBAL_NAME, parent_id: nil)
  admin = User.find_by!(email: "admin@loadtest.local")

  csrs = insert_users((1..250).map { |i| format("csr%03d@loadtest.local", i) }, "user")
  csrs.each_slice(50).with_index { |slice, t| join(slice, teams[t]) }

  insert_users((1..50).map { |i| format("rush%03d@loadtest.local", i) }, "user")

  managers = insert_users((1..12).map { |i| format("mgr%02d@loadtest.local", i) }, "user")
  managers.each_with_index do |manager, i|
    team = teams[i % teams.size]
    join([manager], team)
    GroupManager.create!(user: manager, group: team)
  end

  editors = insert_users((1..5).map { |i| format("editor%02d@loadtest.local", i) }, "editor")
  editors.each_with_index { |editor, i| join([editor], teams[i]) }

  # A returning sub-flow target: three steps, ends in Resolve, comes back.
  verify = Workflow.create!(title: "Verify identity", user: admin, status: "draft")
  v1 = add_step(verify, Steps::Question, 0, title: "Caller verified", question: "Did the caller pass verification?",
                                            answer_type: "yes_no")
  v2 = add_step(verify, Steps::Action, 1, title: "Record verification")
  v3 = add_step(verify, Steps::Resolve, 2, title: "Verified", resolution_type: "success")
  seed_link(v1, v2, 0, condition: "yes")
  seed_link(v1, v3, 1, condition: "no")
  seed_link(v2, v3, 0)
  verify.update!(start_step: v1)
  publish!(verify, global)

  # A handoff target: the run moves here and never returns.
  specialist = Workflow.create!(title: "Billing specialist", user: admin, status: "draft")
  s1 = add_step(specialist, Steps::Message, 0, title: "Specialist takes over")
  s2 = add_step(specialist, Steps::Action, 1, title: "Review the invoice")
  s3 = add_step(specialist, Steps::Resolve, 2, title: "Billing resolved", resolution_type: "success")
  seed_link(s1, s2, 0)
  seed_link(s2, s3, 0)
  specialist.update!(start_step: s1)
  publish!(specialist, global)

  # The caller: verify (returns), then either resolve here or hand off to billing.
  account = Workflow.create!(title: "Account access problem", user: admin, status: "draft")
  a1 = add_step(account, Steps::Message, 0, title: "Greet the caller")
  a2 = add_step(account, Steps::SubFlow, 1, title: "Verify identity", sub_flow_workflow_id: verify.id, sub_flow_returns: true)
  a3 = add_step(account, Steps::Question, 2, title: "Billing issue", question: "Is this about a bill?", answer_type: "yes_no")
  a4 = add_step(account, Steps::SubFlow, 3,
                title: "Hand off to billing", sub_flow_workflow_id: specialist.id, sub_flow_returns: false)
  a5 = add_step(account, Steps::Action, 4, title: "Reset access")
  a6 = add_step(account, Steps::Resolve, 5, title: "Access restored", resolution_type: "success")
  seed_link(a1, a2, 0)
  seed_link(a2, a3, 0)
  seed_link(a3, a4, 0, condition: "yes")
  seed_link(a3, a5, 1, condition: "no")
  seed_link(a5, a6, 0)
  account.update!(start_step: a1)
  publish!(account, global)
end

counts = {
  users: User.count, csrs_in_teams: UserGroup.joins(:user).where(users: { role: "user" }).distinct.count(:user_id),
  managers: GroupManager.count, workflows: Workflow.published.count,
  awaiting_groups: User.awaiting_groups.count
}
puts "department seeded: #{counts.map { |k, v| "#{k}=#{v}" }.join(' ')}"
