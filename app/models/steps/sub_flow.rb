module Steps
  class SubFlow < Step
    belongs_to :target_workflow, class_name: "Workflow", foreign_key: :sub_flow_workflow_id, optional: true, inverse_of: false

    validates :sub_flow_workflow_id, presence: true, on: :publish

    def outcome_summary
      "Run: #{target_workflow&.title || 'Unknown workflow'}"
    end
  end
end
