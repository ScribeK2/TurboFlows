module PerformanceHelper
  # Counts SQL queries executed within a block
  def count_queries(&block)
    queries = []
    counter = lambda { |_name, _start, _finish, _id, payload|
      queries << payload[:sql] unless payload[:sql].match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
    }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    queries
  end

  def assert_max_queries(max, message = nil, &block)
    queries = count_queries(&block)
    msg = message || "Expected at most #{max} queries, got #{queries.size}"
    if queries.size > max
      details = queries.each_with_index.map { |q, i| "  #{i + 1}. #{q}" }.join("\n")
      msg += "\nQueries:\n#{details}"
    end
    assert queries.size <= max, msg
  end

  def assert_completes_within(seconds, message = nil, &block)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    block.call
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert elapsed <= seconds, message || "Expected to complete within #{seconds}s, took #{elapsed.round(3)}s"
  end

  # Seeds realistic data volumes for performance testing
  # Returns a hash of created records for test use
  def seed_performance_data
    admin = User.create!(email: "perf_admin@test.com", password: "password123456", role: "admin")
    editors = 5.times.map do |i|
      User.create!(email: "perf_editor#{i}@test.com", password: "password123456", role: "editor")
    end
    users = 14.times.map do |i|
      User.create!(email: "perf_user#{i}@test.com", password: "password123456", role: "user")
    end

    # 30 groups in 4-level hierarchy
    root_groups = 6.times.map do |i|
      Group.create!(name: "Root Group #{i}")
    end
    level2_groups = root_groups.flat_map do |root|
      2.times.map do |i|
        Group.create!(name: "#{root.name} > L2-#{i}", parent: root)
      end
    end
    level3_groups = level2_groups.first(6).flat_map do |parent|
      1.times.map do |i|
        Group.create!(name: "#{parent.name} > L3-#{i}", parent: parent)
      end
    end

    all_groups = root_groups + level2_groups + level3_groups

    # Assign users to groups
    (editors + users).each_with_index do |user, i|
      group = all_groups[i % all_groups.size]
      user.groups << group unless user.groups.include?(group)
    end

    # 200 workflows spread across groups
    workflows = 200.times.map do |i|
      creator = editors[i % editors.size]
      w = Workflow.create!(
        title: "Performance Test Workflow #{i}",
        description: "Description for workflow #{i} with enough text to be realistic for rendering and search tests.",
        status: i < 180 ? "published" : "draft",
        user: creator,
        steps: build_sample_steps(i)
      )
      # Assign to 1-2 groups
      group = all_groups[i % all_groups.size]
      GroupWorkflow.create!(group: group, workflow: w, is_primary: true) unless w.groups.include?(group)
      if i % 3 == 0 && (second_group = all_groups[(i + 7) % all_groups.size]) != group
        GroupWorkflow.create!(group: second_group, workflow: w) unless w.groups.include?(second_group)
      end
      w
    end

    { admin: admin, editors: editors, users: users, groups: all_groups,
      root_groups: root_groups, workflows: workflows }
  end

  private

  def build_sample_steps(workflow_index)
    step_count = 3 + (workflow_index % 8) # 3-10 steps per workflow
    step_count.times.map do |i|
      step_type = %w[question action sub_flow message resolve escalate][i % 6]
      {
        "id" => SecureRandom.uuid,
        "type" => step_type,
        "title" => "Step #{i + 1} of workflow #{workflow_index}",
        "description" => "Instructions for step #{i + 1}"
      }.tap do |step|
        case step_type
        when "question"
          step["question"] = "What is the answer for step #{i + 1}?"
          step["answer_type"] = "text"
          step["variable_name"] = "var_#{workflow_index}_#{i}"
        when "action"
          step["instructions"] = "Perform action #{i + 1}"
        when "sub_flow"
          # Leave target_workflow_id blank to avoid validation issues
          step["_import_incomplete"] = true
        end
      end
    end
  end
end
