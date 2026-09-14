# Emits CSV rows of finished runs for test/load/seeds/history, whose column list
# this must match. Plain Ruby, no Rails: reads the replica's workflows and CSR
# ids as JSON on stdin, writes CSV on stdout.
#
# Every run is a single-frame call (no sub-flow children): the backlog is there
# for volume, and the live test exercises sub-flows and handoffs itself.

require "json"
require "time"

runs, days = ARGV.map(&:to_i)
meta = JSON.parse($stdin.read)
workflows = meta.fetch("workflows") || []
users = meta.fetch("users") || []
abort "history_rows: no workflows or CSR accounts found; run the seeds first" if workflows.empty? || users.empty?

rng = Random.new(20_260_914)

# [status, outcome, weight]: a call centre where most calls resolve, some
# escalate, and a good share are simply closed mid-run (timed out by the sweep).
ENDINGS = [
  ["completed", "resolved", 70],
  ["completed", "escalated", 10],
  ["completed", "completed", 5],
  ["timeout", "abandoned", 13],
  ["error", "error", 2]
].freeze
TOTAL_WEIGHT = ENDINGS.sum(&:last)

def ending(rng)
  roll = rng.rand(TOTAL_WEIGHT)
  ENDINGS.each do |status, outcome, weight|
    return [status, outcome] if roll < weight

    roll -= weight
  end
end

def step_type(sti)
  sti.delete_prefix("Steps::").gsub(/([a-z])([A-Z])/, '\1_\2').downcase
end

def field(value)
  case value
  when nil then ""
  when Integer then value.to_s
  else %("#{value.to_s.gsub('"', '""')}")
  end
end

now = Time.now.utc
per_day = runs.fdiv(days)
emitted = 0

days.downto(1) do |ago|
  day = now - (ago * 86_400)
  shift_start = Time.utc(day.year, day.month, day.day, 12) # a 10-hour working day in UTC
  count = (((days - ago) + 1) * per_day).round - emitted

  count.times do
    workflow = workflows[rng.rand(workflows.size)]
    steps = workflow.fetch("steps")
    status, outcome = ending(rng)

    abandoned = outcome == "abandoned"
    answered = abandoned ? 1 + rng.rand([steps.size - 1, 1].max) : [rng.rand(5..12), steps.size].min
    duration = abandoned ? rng.rand(30..300) : rng.rand(120..600)
    started = shift_start + rng.rand(36_000)
    completed = started + duration

    clock = started
    path = steps.first(answered).map do |step|
      entry = { "step_title" => step["title"], "step_type" => step_type(step["type"]), "step_uuid" => step["uuid"],
                "started_at" => clock.iso8601(3), "results_delta" => {}, "inputs_delta" => {} }
      clock += duration.fdiv(answered)
      entry
    end

    puts [
      users[rng.rand(users.size)], workflow["id"], workflow["version_id"], "live", status, outcome,
      started.iso8601(6), completed.iso8601(6), duration, JSON.generate(path), "{}", "{}",
      answered, 0, "false", started.iso8601(6), completed.iso8601(6)
    ].map { |value| field(value) }.join(",")
  end

  emitted += count
end
