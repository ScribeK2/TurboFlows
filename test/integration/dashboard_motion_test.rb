require "test_helper"

# Returning to the dashboard jittered. Turbo rendered its cached copy as a
# preview, the sections' 0.5s fadeIn/fadeInUp started, and the fresh page replaced
# it ~360ms later and restarted them mid-flight. Measured 2026-09-12; see
# docs/designs/dashboard-spike-findings.md. This keeps both causes out.
class DashboardMotionTest < ActiveSupport::TestCase
  test "no dashboard view carries an entrance animation" do
    offenders = Rails.root.glob("app/views/dashboard/**/*.erb").select { it.read.match?(/animate-|animation-delay/) }

    assert_empty(offenders.map { |file| file.relative_path_from(Rails.root).to_s })
  end

  test "both dashboard pages skip Turbo's cached preview" do
    %w[home csr].each do |page|
      source = Rails.root.join("app/views/dashboard/#{page}.html.erb").read
      assert_includes source, %(<meta name="turbo-cache-control" content="no-preview">), "dashboard/#{page}"
    end
  end
end
