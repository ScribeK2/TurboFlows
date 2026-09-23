# Gives a Prawn document fonts that can draw what authors actually type.
#
# Prawn's built-in Helvetica is Windows-1252 only, so one "→", "✓" or "≤"
# anywhere in a workflow raised Prawn::Errors::IncompatibleStringEncoding and
# the PDF export was a 500 (26 of 107 dev workflows, 2026-09-23). These are
# the Noto fonts, vendored under vendor/fonts/noto with their licence so the
# Docker image carries them (.dockerignore only drops vendor/bundle):
#
# - Noto Sans, in the four styles the export uses, draws Latin, Greek,
#   Cyrillic, curly quotes, dashes and bullets.
# - Noto Sans Math and Noto Sans Symbols 2 are fallbacks for what Noto Sans
#   lacks: arrows, check marks, comparison signs, stars.
#
# A character none of them has (a colour emoji) is drawn as an empty box
# rather than failing the export.
module PdfFonts
  DIR = Rails.root.join("vendor/fonts/noto")

  FAMILY = {
    "Noto Sans" => {
      normal: DIR.join("NotoSans-Regular.ttf").to_s,
      bold: DIR.join("NotoSans-Bold.ttf").to_s,
      italic: DIR.join("NotoSans-Italic.ttf").to_s,
      bold_italic: DIR.join("NotoSans-BoldItalic.ttf").to_s
    },
    "Noto Sans Math" => { normal: DIR.join("NotoSansMath-Regular.ttf").to_s },
    "Noto Sans Symbols 2" => { normal: DIR.join("NotoSansSymbols2-Regular.ttf").to_s }
  }.freeze

  def self.apply(pdf)
    pdf.font_families.update(FAMILY)
    pdf.font "Noto Sans"
    pdf.fallback_fonts ["Noto Sans Math", "Noto Sans Symbols 2"]
    pdf
  end
end
