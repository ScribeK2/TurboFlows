require "test_helper"

class VersionDiffServiceTest < ActiveSupport::TestCase
  test "identical snapshots produce no changes" do
    snapshot = [{ "id" => "uuid-1", "type" => "question", "title" => "Q1", "position" => 0 }]
    diff = VersionDiffService.call(snapshot, snapshot)
    assert_empty diff[:added]
    assert_empty diff[:removed]
    assert_empty diff[:modified]
  end

  test "detects added steps" do
    old_snapshot = [{ "id" => "uuid-1", "type" => "question", "title" => "Q1", "position" => 0 }]
    new_snapshot = old_snapshot + [{ "id" => "uuid-2", "type" => "action", "title" => "A1", "position" => 1 }]
    diff = VersionDiffService.call(old_snapshot, new_snapshot)
    assert_equal 1, diff[:added].length
    assert_equal "uuid-2", diff[:added].first["id"]
  end

  test "detects removed steps" do
    old_snapshot = [
      { "id" => "uuid-1", "type" => "question", "title" => "Q1", "position" => 0 },
      { "id" => "uuid-2", "type" => "action", "title" => "A1", "position" => 1 }
    ]
    new_snapshot = [{ "id" => "uuid-1", "type" => "question", "title" => "Q1", "position" => 0 }]
    diff = VersionDiffService.call(old_snapshot, new_snapshot)
    assert_equal 1, diff[:removed].length
    assert_equal "uuid-2", diff[:removed].first["id"]
  end

  test "detects modified steps with changed fields" do
    old_snapshot = [{ "id" => "uuid-1", "type" => "question", "title" => "Q1", "position" => 0 }]
    new_snapshot = [{ "id" => "uuid-1", "type" => "question", "title" => "Q1 Updated", "position" => 0 }]
    diff = VersionDiffService.call(old_snapshot, new_snapshot)
    assert_equal 1, diff[:modified].length
    assert_includes diff[:modified].first[:changed_fields], "title"
  end

  test "detects metadata changes" do
    old_meta = { "title" => "Flow A", "graph_mode" => false }
    new_meta = { "title" => "Flow A", "graph_mode" => true }
    diff = VersionDiffService.call([], [], old_metadata: old_meta, new_metadata: new_meta)
    assert_equal({ "graph_mode" => { old: false, new: true } }, diff[:metadata_changes])
  end

  test "handles empty snapshots" do
    diff = VersionDiffService.call([], [])
    assert_empty diff[:added]
    assert_empty diff[:removed]
    assert_empty diff[:modified]
    assert_empty diff[:metadata_changes]
  end

  test "handles nil snapshots gracefully" do
    diff = VersionDiffService.call(nil, nil)
    assert_empty diff[:added]
    assert_empty diff[:removed]
    assert_empty diff[:modified]
  end

  test "multiple changes detected in one step" do
    old_snapshot = [{ "id" => "uuid-1", "type" => "question", "title" => "Q1", "position" => 0, "question" => "Old?" }]
    new_snapshot = [{ "id" => "uuid-1", "type" => "question", "title" => "Q1 New", "position" => 1, "question" => "New?" }]
    diff = VersionDiffService.call(old_snapshot, new_snapshot)
    changed = diff[:modified].first[:changed_fields]
    assert_includes changed, "title"
    assert_includes changed, "position"
    assert_includes changed, "question"
  end
end
