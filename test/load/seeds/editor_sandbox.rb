# A workflow the load test's editors autosave into: owned by an editor and filed
# in Global, which lets every editor edit it (AGENTS.md: editors may edit Global
# workflows another editor owns). Safe to run again; it prints the ids the k6
# editors scenario needs either way.
#
#   bin/rails runner /load/seeds/editor_sandbox.rb

require_relative "guard"
LoadTestSeedGuard.check!

TITLE = "Editor sandbox".freeze

workflow = Workflow.find_by(title: TITLE)
unless workflow
  owner = User.find_by!(email: "editor01@loadtest.local")
  global = Group.find_by!(name: Group::GLOBAL_NAME, parent_id: nil)

  ActiveRecord::Base.transaction do
    workflow = Workflow.create!(title: TITLE, user: owner, status: "draft")
    steps = Array.new(9) do |i|
      Steps::Action.create!(workflow: workflow, uuid: SecureRandom.uuid, position: i, title: "Sandbox step #{i + 1}")
    end
    steps << Steps::Resolve.create!(workflow: workflow, uuid: SecureRandom.uuid, position: 9, title: "Sandbox done",
                                    resolution_type: "success")
    steps.each_cons(2) { |from, to| Transition.create!(step: from, target_step: to, position: 0) }
    workflow.update!(start_step: steps.first)

    GroupWorkflow.create!(group: global, workflow: workflow, is_primary: true)
    result = WorkflowPublisher.publish(workflow, owner)
    raise "publish failed: #{result.error}" unless result.success?
  end
end

step_ids = workflow.steps.where.not(type: "Steps::Resolve").order(:position).pluck(:id)
puts "SANDBOX_WORKFLOW_ID=#{workflow.id}"
puts "SANDBOX_STEP_IDS=#{step_ids.join(',')}"
