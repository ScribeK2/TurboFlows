require "test_helper"

# _global.css defines each dark-mode token twice: once under an explicit
# [data-theme="dark"] opt-in, and once under the prefers-color-scheme media
# query for users who never touched the toggle. The two must stay in lockstep —
# a token updated in one block and not the other produces a theme that is
# subtly wrong for exactly one half of users, which no rendering test catches.
#
# This guards that invariant directly. It is deliberately NOT a generic rule
# ("every [data-theme] block needs a media twin"): the prefers-color-scheme:
# light block has no counterpart by design and would be flagged forever.
class GlobalThemeParityTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/stylesheets/_global.css").read.freeze

  # Each pair is [label, explicit-opt-in selector, system-preference selector].
  PAIRS = [
    [
      "app tokens",
      "\n[data-theme=\"dark\"] {",
      "\n  :root:not([data-theme=\"light\"]) {"
    ],
    [
      "Lexxy tokens",
      "\nhtml[data-theme=\"dark\"] {",
      "\n  html:not([data-theme=\"light\"]) {"
    ]
  ].freeze

  PAIRS.each do |label, explicit_selector, media_selector|
    test "#{label}: dark opt-in and system-preference blocks declare identical values" do
      explicit = custom_properties(block_body(explicit_selector))
      media    = custom_properties(block_body(media_selector))

      assert_operator explicit.size, :>=, 5,
                      "#{label}: parsed only #{explicit.size} declarations from the opt-in block — " \
                      "the selector probably moved. Fix this test rather than deleting it."

      assert_equal explicit.keys.sort, media.keys.sort,
                   "#{label}: the two dark blocks declare different token sets. " \
                   "Only in opt-in: #{(explicit.keys - media.keys).sort.join(', ')}. " \
                   "Only in system-preference: #{(media.keys - explicit.keys).sort.join(', ')}."

      differing = explicit.reject { |name, value| media[name] == value }
      assert_empty differing,
                   "#{label}: #{differing.size} token(s) differ between the two dark blocks. " \
                   "A value changed in one and not the other: " \
                   "#{differing.map { |n, v| "#{n} is '#{v}' vs '#{media[n]}'" }.join('; ')}."
    end
  end

  private

  # Returns the text between the braces of the block introduced by +selector+,
  # which must include its own opening brace. Brace-matched, so nested blocks
  # come along intact and line numbers never enter into it.
  def block_body(selector)
    start = CSS.index(selector)
    assert start, "selector not found in _global.css: #{selector.strip}"

    cursor = start + selector.length
    body_start = cursor
    depth = 1

    while depth.positive? && cursor < CSS.length
      case CSS[cursor]
      when "{" then depth += 1
      when "}" then depth -= 1
      end
      cursor += 1
    end

    assert_equal 0, depth, "unbalanced braces after #{selector.strip}"
    CSS[body_start...(cursor - 1)]
  end

  # Custom properties only. Ordinary declarations (color-scheme: dark) are
  # excluded on purpose — they are not tokens and are not what drifts.
  def custom_properties(body)
    body.scan(/(--[\w-]+)\s*:\s*([^;]+);/)
        .to_h { |name, value| [name, value.strip.squeeze(" ")] }
  end
end
