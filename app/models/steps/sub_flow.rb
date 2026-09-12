module Steps
  class SubFlow < Step
    belongs_to :target_workflow, class_name: "Workflow", foreign_key: :sub_flow_workflow_id, optional: true, inverse_of: false

    def outcome_summary
      "Run: #{target_workflow&.title || 'Unknown workflow'}"
    end

    # A tail call: the run moves to the target workflow and never comes back, so
    # this step ends its own workflow and takes no transitions.
    def hands_off?
      !sub_flow_returns
    end
  end
end
