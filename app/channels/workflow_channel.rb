class WorkflowChannel < ApplicationCable::Channel
  def subscribed
    # Subscribe to updates for a specific workflow
    workflow = find_workflow

    # Allow authorized users (editors/admins) to subscribe, not just owners
    if workflow.can_be_edited_by?(current_user)
      stream_from "workflow:#{workflow.id}"
      stream_from "workflow:#{workflow.id}:autosave"
      stream_from "workflow:#{workflow.id}:presence"

      # Track presence
      add_presence(workflow)

      # Notify other users that this user joined
      broadcast_presence_update(workflow, { type: "user_joined", user: user_info })
    else
      reject
    end
  end

  def unsubscribed
    # Clean up presence when user leaves
    workflow = Workflow.find_by(id: params[:workflow_id])
    if workflow
      remove_presence(workflow)
      broadcast_presence_update(workflow, { type: "user_left", user: user_info })
    end
  end

  # Handle title/description updates from other users
  def workflow_metadata_update(data)
    workflow = find_workflow
    return unless workflow.can_be_edited_by?(current_user)

    Rails.logger.info "WorkflowChannel: Broadcasting workflow_metadata_update - field: #{data['field']}, value length: #{data['value'].to_s.length}"

    ActionCable.server.broadcast("workflow:#{workflow.id}", {
                                   type: "workflow_metadata_update",
                                   field: data["field"], # "title" or "description"
                                   value: data["value"],
                                   user: user_info,
                                   timestamp: Time.current.iso8601
                                 })
  end

  # Handle step updates from other users
  # Supports both AR step updates (by uuid) and legacy JSONB updates (by step_index)
  def step_update(data)
    workflow = find_workflow
    return unless workflow.can_be_edited_by?(current_user)

    # AR path: update by step UUID
    if data["step_uuid"].present?
      Rails.logger.info "WorkflowChannel: Broadcasting AR step_update - uuid: #{data['step_uuid']}"

      ActionCable.server.broadcast("workflow:#{workflow.id}", {
                                     type: "step_update",
                                     step_uuid: data["step_uuid"],
                                     step_data: data["step_data"],
                                     user: user_info,
                                     timestamp: Time.current.iso8601
                                   })
    else
      # Legacy JSONB path
      Rails.logger.info "WorkflowChannel: Broadcasting step_update - step_index: #{data['step_index']}"

      ActionCable.server.broadcast("workflow:#{workflow.id}", {
                                     type: "step_update",
                                     step_index: data["step_index"],
                                     step_data: data["step_data"],
                                     user: user_info,
                                     timestamp: Time.current.iso8601
                                   })
    end
  end

  # Handle auto-save requests from the client
  # Uses optimistic locking to prevent race conditions when multiple users edit.
  # Supports both AR step updates (step_updates array with uuid-keyed data)
  # and legacy JSONB updates (steps array replacing entire JSON column).
  def autosave(data)
    workflow = find_workflow
    return unless workflow.can_be_edited_by?(current_user)

    client_lock_version = (data["lock_version"] || data[:lock_version]).to_i
    title = data["title"] || data[:title] || workflow.title

    Rails.logger.info "Autosave: Workflow #{workflow.id}, client version: #{client_lock_version}, server version: #{workflow.lock_version}"

    begin
      Workflow.transaction do
        workflow.lock!

        if detect_version_conflict?(workflow, client_lock_version)
          broadcast_conflict(workflow)
          return
        end

        # AR step path: receive individual step updates by UUID
        if data["step_updates"].present? && data["step_updates"].is_a?(Array)
          apply_ar_step_updates(workflow, data["step_updates"])
          workflow.title = title if title.present?
          workflow.save!(validate: false)
        else
          # Legacy JSONB path
          steps_data = data["steps"] || data[:steps] || []
          formatted_steps = format_steps_data(steps_data)
          apply_autosave_updates(workflow, title, formatted_steps)
          workflow.save!(validate: false)
        end

        broadcast_autosave_success(workflow)
        Rails.logger.info "Autosave: Successfully saved workflow #{workflow.id}, new version: #{workflow.lock_version}"
      end
    rescue ActiveRecord::StaleObjectError => e
      handle_stale_object_error(workflow, e)
    rescue StandardError => e
      handle_autosave_error(workflow, e)
    end
  end

  # Format steps data for proper storage (extracted for reuse)
  def format_steps_data(steps_data)
    return [] unless steps_data.is_a?(Array)

    steps_data.map do |step|
      next unless step.is_a?(Hash)

      formatted_step = {}

      step.each do |key, value|
        key_str = key.to_s

        case key_str
        when "attachments"
          formatted_step[key_str] = value.is_a?(Array) ? value : []
        when "options"
          formatted_step[key_str] = if value.is_a?(Array)
                                      value.map do |opt|
                                        opt.is_a?(Hash) ? opt.transform_keys(&:to_s) : opt
                                      end
                                    else
                                      []
                                    end
        when "branches"
          formatted_step[key_str] = if value.is_a?(Array)
                                      value.map do |branch|
                                        branch.is_a?(Hash) ? branch.transform_keys(&:to_s) : branch
                                      end
                                    else
                                      []
                                    end
        when "jumps"
          formatted_step[key_str] = if value.is_a?(Array)
                                      value.map do |jump|
                                        jump.is_a?(Hash) ? jump.transform_keys(&:to_s) : jump
                                      end
                                    else
                                      []
                                    end
        when "transitions_json"
          # Parse transitions_json (from Graph Mode UI) into transitions array
          begin
            transitions = value.is_a?(String) ? JSON.parse(value) : value
            if transitions.is_a?(Array)
              formatted_step["transitions"] = transitions.map do |t|
                t.is_a?(Hash) ? t.transform_keys(&:to_s) : t
              end
              Rails.logger.info "Autosave: Parsed transitions_json for step, got #{formatted_step['transitions'].length} transitions"
            end
          rescue JSON::ParserError => e
            Rails.logger.warn "Autosave: Failed to parse transitions_json: #{e.message}"
          end
          # Don't store transitions_json itself, only the parsed transitions
        when "transitions"
          # Handle transitions if passed directly as array
          if value.is_a?(Array)
            formatted_step[key_str] = value.map do |t|
              t.is_a?(Hash) ? t.transform_keys(&:to_s) : t
            end
          elsif value.is_a?(String)
            begin
              parsed = JSON.parse(value)
              formatted_step[key_str] = parsed.is_a?(Array) ? parsed : []
            rescue JSON::ParserError
              formatted_step[key_str] = []
            end
          else
            formatted_step[key_str] = []
          end
        else
          formatted_step[key_str] = value
        end
      end

      formatted_step
    end.compact
  end

  private

  def find_workflow
    @workflow ||= Workflow.find(params[:workflow_id])
  end

  def detect_version_conflict?(workflow, client_lock_version)
    return false unless client_lock_version > 0 && workflow.lock_version != client_lock_version

    Rails.logger.warn "Autosave: Version conflict for workflow #{workflow.id}. Client: #{client_lock_version}, Server: #{workflow.lock_version}"
    true
  end

  def broadcast_conflict(workflow)
    broadcast_to_workflow(workflow, {
                            status: "conflict",
                            lock_version: workflow.lock_version,
                            server_title: workflow.title,
                            server_steps: workflow.steps,
                            conflict_user: user_info,
                            message: "Another user has modified this workflow. Please review the changes.",
                            timestamp: Time.current.iso8601
                          })
  end

  # Apply individual AR step updates received via autosave
  # Each update has { uuid: "...", attributes: { title: "...", ... } }
  def apply_ar_step_updates(workflow, step_updates)
    step_updates.each do |update|
      next unless update.is_a?(Hash) && update["uuid"].present?

      step = workflow.workflow_steps.unscoped.find_by(uuid: update["uuid"], workflow_id: workflow.id)
      next unless step

      attrs = (update["attributes"] || {}).slice(
        "title", "question", "answer_type", "variable_name", "can_resolve",
        "action_type", "target_type", "target_value", "priority", "reason_required",
        "resolution_type", "resolution_code", "notes_required", "survey_trigger",
        "sub_flow_workflow_id", "position"
      )

      # Rich text fields need special handling
      %w[instructions content notes].each do |rt_field|
        if update.dig("attributes", rt_field).present?
          step.send(:"#{rt_field}=", update["attributes"][rt_field]) if step.respond_to?(:"#{rt_field}=")
        end
      end

      step.update!(attrs) if attrs.present?
    end
  end

  def apply_autosave_updates(workflow, title, formatted_steps)
    workflow.title = title if title.present?
    workflow.steps = merge_steps(workflow.steps, formatted_steps)
  end

  # Merge autosaved steps with existing steps to preserve fields
  # the client may not have extracted (e.g., options, output_fields).
  # Match steps by ID and overlay submitted fields onto existing data.
  def merge_steps(existing_steps, submitted_steps)
    return submitted_steps unless existing_steps.present? && submitted_steps.present?

    existing_by_id = existing_steps.each_with_object({}) { |s, h| h[s['id']] = s if s['id'].present? }
    submitted_steps.map do |submitted_step|
      existing = existing_by_id[submitted_step['id']]
      if existing
        merged = existing.deep_dup
        submitted_step.each { |key, value| merged[key] = value }
        merged
      else
        submitted_step
      end
    end
  end

  def broadcast_autosave_success(workflow)
    broadcast_to_workflow(workflow, {
                            status: "saved",
                            lock_version: workflow.lock_version,
                            saved_by: user_info,
                            timestamp: Time.current.iso8601
                          })

    ActionCable.server.broadcast("workflow:#{workflow.id}", {
                                   type: "workflow_saved",
                                   lock_version: workflow.lock_version,
                                   title: workflow.title,
                                   updated_at: workflow.updated_at.iso8601,
                                   saved_by: user_info,
                                   timestamp: Time.current.iso8601
                                 })
  end

  def handle_stale_object_error(workflow, error)
    workflow.reload
    Rails.logger.warn "Autosave: Stale object error for workflow #{workflow.id}: #{error.message}"

    broadcast_to_workflow(workflow, {
                            status: "conflict",
                            lock_version: workflow.lock_version,
                            server_title: workflow.title,
                            server_steps: workflow.steps,
                            message: "Your changes could not be saved due to a conflict. Please refresh and try again.",
                            timestamp: Time.current.iso8601
                          })
  end

  def handle_autosave_error(workflow, error)
    Rails.logger.error "Autosave: Failed to save workflow #{workflow.id}: #{error.message}"
    Rails.logger.error error.backtrace.first(10).join("\n")

    broadcast_to_workflow(workflow, {
                            status: "error",
                            errors: [error.message],
                            timestamp: Time.current.iso8601
                          })
  end

  def broadcast_to_workflow(workflow, message)
    ActionCable.server.broadcast("workflow:#{workflow.id}:autosave", message)
  end

  def user_info
    {
      id: current_user.id,
      email: current_user.email,
      name: current_user.email.split("@").first.titleize
    }
  end

  # ==========================================================================
  # Presence Tracking
  # ==========================================================================
  # Uses Redis in production (via ActionCable's pubsub) for multi-worker support
  # Falls back to in-memory store for development/test (single worker)

  def add_presence(workflow)
    presence_key = presence_redis_key(workflow)

    if redis_available?
      redis_connection.sadd(presence_key, current_user.id.to_s)
      redis_connection.expire(presence_key, 3600) # 1 hour TTL
    else
      # Development/test: thread-safe in-memory store (single worker only)
      presence_mutex.synchronize do
        memory_presence_store[presence_key] ||= Set.new
        memory_presence_store[presence_key].add(current_user.id)
      end
    end
  end

  def remove_presence(workflow)
    presence_key = presence_redis_key(workflow)

    if redis_available?
      redis_connection.srem(presence_key, current_user.id.to_s)
    else
      presence_mutex.synchronize do
        memory_presence_store[presence_key]&.delete(current_user.id)
        memory_presence_store.delete(presence_key) if memory_presence_store[presence_key] && memory_presence_store[presence_key].empty?
      end
    end
  end

  def get_active_users(workflow)
    presence_key = presence_redis_key(workflow)

    user_ids = if redis_available?
                 redis_connection.smembers(presence_key).map(&:to_i)
               else
                 presence_mutex.synchronize do
                   (memory_presence_store[presence_key] || Set.new).to_a
                 end
               end

    return [] if user_ids.empty?

    User.where(id: user_ids).map do |user|
      { id: user.id, email: user.email, name: user.email.split("@").first.titleize }
    end
  end

  # Redis connection via ActionCable's pubsub (properly handles connection pooling)
  def redis_connection
    @redis_connection ||= begin
      pubsub = ActionCable.server.pubsub
      # Access Redis through ActionCable's pubsub adapter
      if pubsub.respond_to?(:redis_connection_for_subscriptions)
        # Rails 7+ style
        pubsub.send(:redis_connection_for_subscriptions)
      elsif defined?(Redis) && ENV['REDIS_URL'].present?
        # Direct Redis connection (production)
        Redis.new(url: ENV.fetch('REDIS_URL', nil))
      else
        nil
      end
    end
  end

  def redis_available?
    return false unless Rails.env.production? || ENV['REDIS_URL'].present?

    redis_connection.present?
  rescue StandardError => e
    Rails.logger.warn "Redis not available for presence tracking: #{e.message}"
    false
  end

  def presence_redis_key(workflow)
    "kizuflow:presence:workflow:#{workflow.id}"
  end

  # Thread-safe in-memory store for development/test
  def memory_presence_store
    @@memory_presence_store ||= {}
  end

  def presence_mutex
    @@presence_mutex ||= Mutex.new
  end

  def broadcast_presence_update(workflow, message)
    ActionCable.server.broadcast("workflow:#{workflow.id}:presence", {
                                   **message,
                                   active_users: get_active_users(workflow),
                                   timestamp: Time.current.iso8601
                                 })
  end
end
