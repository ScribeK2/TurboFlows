module ApiProvenanceHelper
  # "Created via API · <token name>" for a workflow an API token made; nil
  # otherwise. Shown whether the token is still live or not: provenance is
  # history. A deleted token nulls api_token_id, and the label goes with it.
  def api_provenance_badge(workflow)
    token = workflow.api_token
    return unless token

    tag.span("Created via API · #{token.name}", class: "badge badge--info",
                                                title: "Made through the API token “#{token.name}”")
  end
end
