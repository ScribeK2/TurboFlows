# frozen_string_literal: true

module MultiSessionHelper
  def assert_no_full_reload(&)
    page.execute_script("document.body.dataset.turboMarker = 'alive'")
    yield
    marker = page.evaluate_script('document.body.dataset.turboMarker')

    assert_equal 'alive', marker, 'Full page reload detected — Turbo navigation broken'
  end
end
