class Steps::SubFlow < Step
  belongs_to :target_workflow, class_name: "Workflow", foreign_key: :sub_flow_workflow_id

  validates :sub_flow_workflow_id, presence: true

  def outcome_summary
    "Run: #{target_workflow&.title || 'Unknown workflow'}"
  end
end
