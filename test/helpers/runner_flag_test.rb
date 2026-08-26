require "test_helper"

# The stacked runner flag.
#
# One global switch rather than a per-user one: anonymous share-link runs have
# no user to flag, and that is the surface with no console and no session to ask
# about afterwards. A workflow's author and the person opening their share link
# must see the same runner.
class RunnerFlagTest < ActionView::TestCase
  include RunnerHelper

  test "the stacked runner is off unless the deployment turns it on" do
    assert_not stacked_runner?
  end

  test "the flag is read per request, not frozen at boot" do
    original = Rails.configuration.x.stacked_runner
    Rails.configuration.x.stacked_runner = true

    assert_predicate self, :stacked_runner?, "a test or a console must be able to flip it"
  ensure
    Rails.configuration.x.stacked_runner = original
  end
end
