# The data checks that decide a load test (grill Q24). A failure here blocks the
# launch, whatever the latency numbers say. Run it inside the replica's web
# container after a test, feeding it the k6 console log:
#
#   docker exec -i turboflows-vm docker exec -i -e CHECK_SINCE=2026-09-15T09:00:00Z turboflows-web \
#     bin/rails runner /load/checks/integrity.rb < tmp/load-results/<run>/console.log
#
# CHECK_SINCE limits the run-shape checks to runs created during the test, so a
# seeded history is not re-examined every time. Exits 1 if any check fails.
#
# What it cannot see, and test/load/checks/run covers instead: 500s in the web
# log and processes killed for memory.

class IntegrityReport
  EXAMPLES = 10

  def initialize
    @failures = 0
  end

  def check(name, problems, detail = nil)
    suffix = detail ? " (#{detail})" : nil
    if problems.empty?
      puts "PASS  #{name}#{suffix}"
    else
      @failures += 1
      puts "FAIL  #{name}: #{problems.size} problem(s)#{suffix}"
      problems.first(EXAMPLES).each { |problem| puts "        #{problem}" }
    end
  end

  def finish
    puts
    puts @failures.zero? ? "ALL CHECKS PASSED" : "#{@failures} CHECK(S) FAILED"
    exit(@failures.zero? ? 0 : 1)
  end
end

since = ENV["CHECK_SINCE"].present? ? Time.iso8601(ENV.fetch("CHECK_SINCE")) : 1.day.ago
report = IntegrityReport.new

# --- What k6 said happened -----------------------------------------------------
acks = Hash.new(0)
halts = 0
$stdin.each_line do |line|
  next unless (match = line.match(/(ACK|HALT) (\d+) ([0-9a-f-]{36}|null)/))

  if match[1] == "ACK"
    acks[[match[2].to_i, match[3]]] += 1
  else
    halts += 1
  end
end

frames = Scenario.where(created_at: since..).to_a
by_id = frames.index_by(&:id)

# 1. Every answer the server acknowledged is in that run's execution path.
missing = acks.keys.filter_map do |scenario_id, step_uuid|
  scenario = by_id[scenario_id] || Scenario.find_by(id: scenario_id)
  next "scenario #{scenario_id}: gone (acknowledged answer on step #{step_uuid})" if scenario.nil?
  next if step_uuid == "null"

  recorded = Array(scenario.execution_path).any? { |entry| entry["step_uuid"] == step_uuid }
  "scenario #{scenario_id}: acknowledged answer on step #{step_uuid} is not in execution_path" unless recorded
end
report.check("acknowledged answers are recorded", missing,
             "#{acks.values.sum} acknowledged, #{halts} halted and told to the agent")

# 2. No run is stuck: something the agent can still act on exists.
stuck = frames.reject(&:terminal?).filter_map do |frame|
  if frame.awaiting_subflow?
    next if frame.active_child_scenario || frame.parked? # parked offers Resume

    next "scenario #{frame.id}: awaiting a sub-flow with no live child and no Resume"
  end

  if frame.current_step.nil? && !frame.parked?
    next "scenario #{frame.id}: active with no current step (node #{frame.current_node_uuid.inspect})"
  end

  head = frame.run_origin.run_head
  "scenario #{frame.id}: still #{frame.status} but its run has ended at scenario #{head.id} (#{head.status})" if head.terminal?
end
report.check("no run is left unfinishable", stuck, "#{frames.count { |f| !f.terminal? }} unfinished frames examined")

# 3. completed_at agrees with whether the frame has ended.
stamps = frames.filter_map do |frame|
  if frame.terminal? && frame.completed_at.nil?
    "scenario #{frame.id}: #{frame.status} with no completed_at"
  elsif !frame.terminal? && frame.completed_at.present?
    "scenario #{frame.id}: #{frame.status} but completed_at #{frame.completed_at.iso8601}"
  end
end
report.check("completed_at matches every frame's state", stamps)

# 4. Every frame of a call records the call it belongs to.
origins = frames.filter_map do |frame|
  expected = frame.run_origin
  want = expected.id == frame.id ? nil : expected.id
  next if frame.run_origin_id == want

  "scenario #{frame.id}: run_origin_id #{frame.run_origin_id.inspect}, but its call starts at #{want.inspect}"
end
report.check("run_origin_id names each frame's call", origins)

# 5. The idle sweep closed only runs that really were idle.
timeout_hours = Scenario.idle_timeout_hours
premature = Scenario.where(status: "timeout", updated_at: since..).filter_map do |frame|
  next if frame.completed_at && frame.completed_at <= frame.updated_at - timeout_hours.hours

  "scenario #{frame.id}: timed out at #{frame.updated_at.iso8601}, last activity #{frame.completed_at&.iso8601.inspect}"
end
report.check("the idle sweep settled only idle runs", premature, "timeout #{timeout_hours}h")

# 6. Rollups written during the test match the runs they summarise. Totals per
# day, workflow and purpose, over runs that had started when the rollup was
# written: outcomes may move afterwards, and later runs are not in it yet.
rollup_problems = []
ScenarioRollup.where(created_at: since..).group_by { |r| [r.day, r.workflow_id, r.purpose] }.each do |(day, workflow_id, purpose), rows|
  built_at = rows.map(&:created_at).min
  expected = Scenario.where(workflow_id: workflow_id, purpose: purpose,
                            started_at: day.beginning_of_day..[day.end_of_day, built_at].min).count
  actual = rows.sum(&:runs_count)
  next if expected == actual

  rollup_problems << "#{day} workflow #{workflow_id} #{purpose}: rollup says #{actual} runs, #{expected} had started when it was written"
end
report.check("rollups match the runs they count", rollup_problems)

report.finish
