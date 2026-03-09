class Steps::SubFlow < Step
  belongs_to :target_workflow, class_name: "Workflow", foreign_key: :sub_flow_workflow_id

  validates :sub_flow_workflow_id, presence: true
end
