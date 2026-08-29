# Advancing a run to the next step a user can actually answer.
#
# Not every node is renderable. A sub_flow step starts a child scenario and has
# no UI of its own; a resolve step inside a child exists to hand control back to
# the parent. Landing on either means the run is mid-move, not waiting.
#
# Both runner shells used to auto-process those inside GET step and redirect —
# sometimes several times over, since a sub_flow can lead to a child whose first
# step is another sub_flow. That made GET a mutating request, and spread one
# loop across two controllers that had already drifted apart.
#
# The loop lives here instead, and it reports where the run ended up so a caller
# can stream the result without re-deriving it. The run may finish on a
# descendant of the scenario it started on, or on an ancestor.
class ScenarioSettler
  # Where the run came to rest.
  #
  #   scenario  the leaf the run now lives on — post answers here
  #   outcome   the last Outcome, so callers can branch on blocked/resolved
  #   traversed entries appended while settling, oldest first, so a transcript
  #             can show a row per auto-processed step instead of a hole
  Settled = Data.define(:scenario, :outcome, :traversed) do
    delegate :blocked?, to: :outcome
    delegate :resolved?, to: :outcome
    delegate :halted?, to: :outcome
  end

  # A node the user is never shown.
  #
  # A sub_flow has no UI. A resolve inside a child is the sub-flow finishing,
  # not the run finishing, so the agent should not be asked to acknowledge it —
  # a top-level resolve is a different thing and does get acknowledged.
  #
  # Scenario#parked? asks the same question, which is why this is public: "a
  # node the settler would move past" and "a node the run cannot rest on" have
  # to be one rule. They were two, and drifted.
  def self.auto_processable?(scenario, step)
    return true if step.step_type == "sub_flow"

    # parent_scenario_id, not parent_scenario: "is this a child" is answered by
    # the foreign key, and this runs in the settle loop and again in
    # Scenario#parked? on every render. Loading the association to ask cost a
    # query per advance for nothing.
    step.step_type == "resolve" && scenario.parent_scenario_id.present?
  end

  def initialize(scenario)
    @scenario = scenario
  end

  # Process one answer, then keep going while the run is on a node nobody can
  # answer. Returns Settled.
  def settle(answer = nil, resolved_here: false)
    @traversed = []
    current = @scenario
    outcome = process(current, answer, resolved_here: resolved_here)

    loop do
      break if outcome.blocked? || outcome.halted?

      if outcome.awaiting_subflow?
        moved = descend(current) or break
        current, outcome = moved
      elsif outcome.resolved?
        moved = ascend(current) or break
        current, outcome = moved
        next if outcome.resolved? # the parent finished too — keep climbing
      end

      step = current.current_step
      break unless step && auto_processable?(current, step)

      outcome = process(current)
    end

    Settled.new(scenario: current, outcome: outcome, traversed: @traversed)
  end

  # Move a freshly created run off an opening step that has no UI.
  #
  # Nothing POSTs between creating a scenario and its first GET — every creation
  # site sets current_node_uuid to the workflow's start node and redirects — so
  # a workflow whose first step is a sub_flow would land on a node the runner
  # cannot render now that GET no longer moves the run.
  #
  # Returns the scenario the run now lives on. Unlike #settle it processes
  # nothing when the opening step is an ordinary one, so an unanswered run keeps
  # an empty history.
  def settle_from_start
    step = @scenario.current_step
    return @scenario unless step && auto_processable?(@scenario, step)

    settle.scenario
  end

  private

  # Into the child a sub_flow step just started.
  #
  # Crossing the boundary is a move, not a step: the child may well open on a
  # question, and the run has still advanced into it. Conflating the two left
  # the run reported as sitting on the parent's invisible sub_flow node.
  def descend(current)
    child = current.active_child_scenario
    return nil unless child

    [child, ScenarioStepProcessor::Outcome.advanced]
  end

  # Back out to the parent a finished child belongs to.
  #
  # The parent may finish on the same move — a sub-flow that was its last step —
  # in which case the caller climbs again rather than resting on a completed
  # frame partway up.
  def ascend(current)
    parent = current.parent_scenario
    return nil unless parent
    return nil unless parent.process_subflow_completion

    parent.reload
    outcome = parent.complete? ? ScenarioStepProcessor::Outcome.resolved : ScenarioStepProcessor::Outcome.advanced
    [parent, outcome]
  end

  def auto_processable?(scenario, step)
    self.class.auto_processable?(scenario, step)
  end

  # Process one step, keeping whatever it appended.
  #
  # Recorded here, as it happens, rather than diffed from the root's path
  # afterwards: a child scenario's entries live on the child, so a root-level
  # diff saw nothing at all for the steps inside a sub-flow — exactly the steps
  # a transcript most needs, since the user answered them.
  def process(scenario, answer = nil, resolved_here: false)
    before = (scenario.execution_path || []).length
    outcome = scenario.process_step(answer, resolved_here: resolved_here)
    @traversed.concat((scenario.execution_path || []).drop(before))
    outcome
  end
end
