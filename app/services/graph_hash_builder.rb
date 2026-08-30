# Builds the { uuid => step_hash } structure GraphValidator consumes, from a
# collection of AR Steps.
#
# This existed in three places before: Workflow#validation_graph_hash,
# WorkflowHealthCheck#build_graph_hash, and inline in
# WorkflowGraphConverter#validate_converted_graph. The duplication was over a
# *steps collection*, not over a workflow, which is why the converter — which
# validates an arbitrary array rather than workflow.steps — could not reuse the
# Workflow method and grew its own copy.
#
# Callers own their own preloading. Pass a collection with
# `includes(transitions: :target_step)` to avoid N+1, or a collection whose
# transitions have been reloaded when they were just written.
#
# WorkflowGraphConverter#validate_simulated_conversion is deliberately NOT a
# caller: it fabricates transitions that do not exist yet, so it is a different
# structure that merely looks similar.
class GraphHashBuilder
  def self.call(steps)
    new(steps).call
  end

  def initialize(steps)
    @steps = steps
  end

  def call
    @steps.to_h do |step|
      [step.uuid, {
        "id" => step.uuid,
        "type" => step.type.demodulize.underscore,
        "title" => step.title,
        "transitions" => step.transitions.map do |t|
          { "target_uuid" => t.target_step&.uuid, "condition" => t.condition }
        end
      }]
    end
  end
end
