# frozen_string_literal: true

# The stacked runner: answering a step collapses it in place and appends the
# next one below, instead of replacing the page.
#
# One global switch, not a per-user one. Anonymous share-link runs have no user
# to flag, and that is the surface with the least ability to report what it saw
# — a workflow's author and the person opening their share link must not get
# different runners.
#
# REMOVAL CONDITION: delete this file, RunnerHelper#stacked_runner?, the classic
# response branch and runner/_trail after two weeks of Player traffic with no
# rollback. A flag with no exit date is how both runners survive for a year.
Rails.application.configure do
  config.x.stacked_runner = ActiveModel::Type::Boolean.new.cast(ENV.fetch("STACKED_RUNNER", false))
end
