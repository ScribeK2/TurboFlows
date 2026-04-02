# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_02_134509) do
  create_table "action_text_rich_texts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "folders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "group_id", null: false
    t.string "name", null: false
    t.integer "parent_id"
    t.integer "position", default: 0
    t.datetime "updated_at", null: false
    t.index ["group_id", "name"], name: "index_folders_on_group_id_and_name", unique: true
    t.index ["group_id", "position"], name: "index_folders_on_group_id_and_position"
    t.index ["group_id"], name: "index_folders_on_group_id"
    t.index ["parent_id"], name: "index_folders_on_parent_id"
  end

  create_table "group_workflows", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "folder_id"
    t.integer "group_id", null: false
    t.boolean "is_primary", default: false, null: false
    t.datetime "updated_at", null: false
    t.integer "workflow_id", null: false
    t.index ["folder_id"], name: "index_group_workflows_on_folder_id"
    t.index ["group_id", "workflow_id"], name: "index_group_workflows_on_group_and_workflow", unique: true
    t.index ["group_id"], name: "index_group_workflows_on_group_id"
    t.index ["workflow_id"], name: "index_group_workflows_on_workflow_id"
  end

  create_table "groups", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.integer "parent_id"
    t.integer "position"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_groups_on_name"
    t.index ["parent_id", "position"], name: "index_groups_on_parent_id_and_position"
    t.index ["parent_id"], name: "index_groups_on_parent_id"
  end

  create_table "scenarios", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "current_node_uuid"
    t.integer "current_step_index", default: 0, null: false
    t.integer "duration_seconds"
    t.json "execution_path"
    t.json "inputs"
    t.string "outcome"
    t.integer "parent_scenario_id"
    t.string "purpose", default: "simulation", null: false
    t.json "results"
    t.string "resume_node_uuid"
    t.boolean "shared_access", default: false, null: false
    t.datetime "started_at"
    t.string "status", default: "active", null: false
    t.integer "stopped_at_step_index"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.integer "workflow_id", null: false
    t.integer "workflow_version_id"
    t.index ["current_node_uuid"], name: "index_scenarios_on_current_node_uuid"
    t.index ["outcome"], name: "index_scenarios_on_outcome"
    t.index ["parent_scenario_id"], name: "index_scenarios_on_parent_scenario_id"
    t.index ["purpose", "started_at"], name: "index_scenarios_on_purpose_and_started_at"
    t.index ["status"], name: "index_scenarios_on_status"
    t.index ["user_id", "purpose"], name: "index_scenarios_on_user_id_and_purpose"
    t.index ["user_id"], name: "index_scenarios_on_user_id"
    t.index ["workflow_id", "purpose", "outcome"], name: "index_scenarios_on_workflow_id_and_purpose_and_outcome"
    t.index ["workflow_id"], name: "index_scenarios_on_workflow_id"
    t.index ["workflow_version_id"], name: "index_scenarios_on_workflow_version_id"
  end

  create_table "step_responses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "responses", default: {}
    t.integer "scenario_id", null: false
    t.integer "step_id", null: false
    t.datetime "submitted_at", null: false
    t.datetime "updated_at", null: false
    t.index ["scenario_id", "step_id"], name: "index_step_responses_on_scenario_id_and_step_id"
    t.index ["scenario_id"], name: "index_step_responses_on_scenario_id"
    t.index ["step_id"], name: "index_step_responses_on_step_id"
  end

  create_table "steps", force: :cascade do |t|
    t.string "action_type"
    t.string "answer_type"
    t.boolean "can_resolve", default: false
    t.datetime "created_at", null: false
    t.json "jumps"
    t.integer "lock_version", default: 0, null: false
    t.boolean "notes_required", default: false
    t.json "options"
    t.json "output_fields"
    t.integer "position", null: false
    t.integer "position_x"
    t.integer "position_y"
    t.string "priority"
    t.string "question"
    t.boolean "reason_required", default: false
    t.string "resolution_code"
    t.string "resolution_type"
    t.integer "sub_flow_workflow_id"
    t.boolean "survey_trigger", default: false
    t.string "target_type"
    t.string "target_value"
    t.string "title"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.string "uuid", null: false
    t.json "variable_mapping"
    t.string "variable_name"
    t.integer "workflow_id", null: false
    t.index ["sub_flow_workflow_id"], name: "index_steps_on_sub_flow_workflow_id"
    t.index ["type"], name: "index_steps_on_type"
    t.index ["workflow_id", "position"], name: "index_steps_on_workflow_id_and_position"
    t.index ["workflow_id", "uuid"], name: "index_steps_on_workflow_id_and_uuid", unique: true
    t.index ["workflow_id"], name: "index_steps_on_workflow_id"
  end

  create_table "taggings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "tag_id", null: false
    t.datetime "updated_at", null: false
    t.integer "workflow_id", null: false
    t.index ["tag_id", "workflow_id"], name: "index_taggings_uniqueness", unique: true
    t.index ["tag_id"], name: "index_taggings_on_tag_id"
    t.index ["workflow_id"], name: "index_taggings_on_workflow_id"
  end

  create_table "tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index "LOWER(name)", name: "index_tags_on_lower_name", unique: true
  end

  create_table "transitions", force: :cascade do |t|
    t.string "condition"
    t.datetime "created_at", null: false
    t.string "label"
    t.integer "position"
    t.integer "step_id", null: false
    t.integer "target_step_id", null: false
    t.datetime "updated_at", null: false
    t.index ["step_id", "target_step_id", "condition"], name: "index_transitions_on_step_id_and_target_step_id_and_condition", unique: true
    t.index ["step_id"], name: "index_transitions_on_step_id"
    t.index ["target_step_id"], name: "index_transitions_on_target_step_id"
  end

  create_table "user_groups", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "group_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["group_id"], name: "index_user_groups_on_group_id"
    t.index ["user_id", "group_id"], name: "index_user_groups_on_user_and_group", unique: true
    t.index ["user_id"], name: "index_user_groups_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name", limit: 50
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.datetime "locked_at"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.string "role", default: "user", null: false
    t.string "unlock_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["role"], name: "index_users_on_role"
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
  end

  create_table "workflow_versions", force: :cascade do |t|
    t.text "changelog"
    t.datetime "created_at", null: false
    t.json "metadata_snapshot", default: {}, null: false
    t.datetime "published_at", null: false
    t.integer "published_by_id", null: false
    t.json "steps_snapshot", null: false
    t.datetime "updated_at", null: false
    t.integer "version_number", null: false
    t.integer "workflow_id", null: false
    t.index ["published_at"], name: "index_workflow_versions_on_published_at"
    t.index ["published_by_id"], name: "index_workflow_versions_on_published_by_id"
    t.index ["workflow_id", "version_number"], name: "index_workflow_versions_on_workflow_id_and_version_number", unique: true
    t.index ["workflow_id"], name: "index_workflow_versions_on_workflow_id"
  end

  create_table "workflows", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "draft_expires_at"
    t.boolean "embed_enabled", default: false, null: false
    t.boolean "graph_mode", default: true, null: false
    t.boolean "is_public", default: false, null: false
    t.integer "lock_version", default: 0, null: false
    t.integer "published_version_id"
    t.string "share_token"
    t.integer "start_step_id"
    t.string "status", default: "published", null: false
    t.integer "steps_count", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["created_at"], name: "index_workflows_on_created_at"
    t.index ["draft_expires_at"], name: "index_workflows_on_draft_expires_at"
    t.index ["graph_mode"], name: "index_workflows_on_graph_mode"
    t.index ["is_public"], name: "index_workflows_on_is_public"
    t.index ["published_version_id"], name: "index_workflows_on_published_version_id"
    t.index ["share_token"], name: "index_workflows_on_share_token", unique: true
    t.index ["start_step_id"], name: "index_workflows_on_start_step_id"
    t.index ["status", "user_id"], name: "index_workflows_on_status_and_user_id"
    t.index ["status"], name: "index_workflows_on_status"
    t.index ["updated_at"], name: "index_workflows_on_updated_at"
    t.index ["user_id"], name: "index_workflows_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "folders", "groups"
  add_foreign_key "group_workflows", "folders"
  add_foreign_key "group_workflows", "groups"
  add_foreign_key "group_workflows", "workflows"
  add_foreign_key "scenarios", "scenarios", column: "parent_scenario_id", on_delete: :nullify
  add_foreign_key "scenarios", "users"
  add_foreign_key "scenarios", "workflow_versions", on_delete: :nullify
  add_foreign_key "scenarios", "workflows"
  add_foreign_key "step_responses", "scenarios"
  add_foreign_key "step_responses", "steps"
  add_foreign_key "steps", "workflows"
  add_foreign_key "taggings", "tags"
  add_foreign_key "taggings", "workflows"
  add_foreign_key "transitions", "steps"
  add_foreign_key "transitions", "steps", column: "target_step_id"
  add_foreign_key "user_groups", "groups"
  add_foreign_key "user_groups", "users"
  add_foreign_key "workflow_versions", "users", column: "published_by_id"
  add_foreign_key "workflow_versions", "workflows"
  add_foreign_key "workflows", "steps", column: "start_step_id"
  add_foreign_key "workflows", "users"
  add_foreign_key "workflows", "workflow_versions", column: "published_version_id"
end
