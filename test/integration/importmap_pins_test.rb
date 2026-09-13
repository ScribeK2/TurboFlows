require "test_helper"

# Lexxy uploads an image with `await import("@rails/activestorage")`, resolved
# in the browser through the importmap. From when Lexxy was added (2026-03-09)
# until 2026-09-13 that package was never pinned, and the failure was silent:
# the editor previewed the chosen image, nothing uploaded, nothing was logged,
# and the step saved without it. So every bare module Lexxy imports, lazily or
# statically, must be pinned, including ones a later Lexxy release adds.
class ImportmapPinsTest < ActiveSupport::TestCase
  BARE = %r{[^"'./][^"']*}

  test "every bare module Lexxy imports is pinned and its asset exists" do
    source = File.read(Rails.application.assets.load_path.find("lexxy.js").path)
    imported = source.scan(/\bimport\s*\(\s*["'](#{BARE})["']\s*\)/o).flatten |
               source.scan(/^\s*import\s[^;]*?\bfrom\s*["'](#{BARE})["']/o).flatten

    assert_includes imported, "@rails/activestorage", "the lazy upload import this test exists for"

    packages = Rails.application.importmap.packages
    missing = imported.reject { packages.key?(it) }
    assert_empty missing, "Lexxy imports these without an importmap pin, so that code fails in the browser"

    unresolvable = imported.reject { Rails.application.assets.load_path.find(packages.fetch(it).path) }
    assert_empty unresolvable, "these pins point at assets that don't exist"
  end
end
