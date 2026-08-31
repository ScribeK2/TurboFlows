require "test_helper"

# The variant processor is a config line that nothing else exercises: the app has
# exactly one variant call site (app/views/active_storage/blobs/_blob.html.erb,
# which Action Text renders for image attachments), and it only runs when someone
# attaches an image. A processor that is configured but not installed therefore
# fails in production while the whole suite stays green — which is how
# :mini_magick survived in a runtime image that only ever had libvips.
class ActiveStorageVariantTest < ActiveSupport::TestCase
  # The original defect was drift between these two files, not a bug in either:
  # the processor said :mini_magick, the runtime layer installed only libvips, and
  # mini_magick is a wrapper that shells out to a binary that was never there.
  test "configured variant processor matches the library the runtime image installs" do
    assert_equal :vips, ActiveStorage.variant_processor

    runtime_layer = Rails.root.join("Dockerfile").read.split("FROM").second

    assert_match(/apt-get install .*\blibvips\b/, runtime_layer)
  end

  test "the configured backend is loadable" do
    require "vips"

    assert_predicate Vips.version_string, :present?
  end

  test "processes the variant Action Text image attachments ask for" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: file_fixture("sample_image.png").open,
      filename: "sample_image.png",
      content_type: "image/png"
    )

    variant = blob.representation(resize_to_limit: [100, 100]).processed

    require "vips"
    image = Vips::Image.new_from_buffer(variant.image.blob.download, "")

    assert_equal 100, image.width
    assert_equal 50, image.height
  ensure
    blob&.purge
  end
end
