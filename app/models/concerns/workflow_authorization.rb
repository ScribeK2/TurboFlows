# Handles authorization logic for workflows.
# Determines who can view, edit, and delete workflows based on user roles and group membership.
module WorkflowAuthorization
  extend ActiveSupport::Concern

  # Check if a user can view this workflow
  #
  # Access rules:
  # - Admins: can view all workflows
  # - Editors: can view own workflows, public workflows, or workflows in assigned groups
  # - Users: can view public workflows or workflows in assigned groups
  #
  # @param user [User] The user to check access for
  # @return [Boolean] True if user can view this workflow
  def can_be_viewed_by?(user)
    return false unless user

    # Admins can view all workflows
    return true if user.admin?

    # Editors can view their own workflows + public workflows + workflows in assigned groups
    if user.editor?
      return true if user == self.user
      return true if is_public?

      # Check if workflow is in user's assigned groups
      group_ids = cached_accessible_group_ids(user)
      if group_ids.any? && workflow_in_groups?(group_ids)
        return true
      end
      return true if workflow_has_no_groups? # Workflows without groups (backward compatibility)

      return false
    end

    # Regular users: can view public workflows + workflows in assigned groups only
    return true if is_public?

    # Check if workflow is in user's assigned groups
    group_ids = cached_accessible_group_ids(user)
    return true if group_ids.any? && workflow_in_groups?(group_ids)

    false
  end

  # Check if a user can edit this workflow
  #
  # Access rules:
  # - Admins: can edit all workflows
  # - Editors: can edit own workflows or public workflows created by other editors
  # - Users: cannot edit workflows
  #
  # @param user [User] The user to check access for
  # @return [Boolean] True if user can edit this workflow
  def can_be_edited_by?(user)
    return false unless user

    # Admins can edit all workflows
    return true if user.admin?

    # Editors can edit their own workflows or public workflows created by other editors
    if user.editor?
      return true if user == self.user
      return true if is_public? && self.user.editor?
    end

    false
  end

  # Check if a user can delete this workflow
  #
  # Access rules:
  # - Admins: can delete all workflows
  # - Editors: can only delete their own workflows
  # - Users: cannot delete workflows
  #
  # @param user [User] The user to check access for
  # @return [Boolean] True if user can delete this workflow
  def can_be_deleted_by?(user)
    return false unless user

    # Admins can delete all workflows
    return true if user.admin?

    # Editors can only delete their own workflows
    user.editor? && user == self.user
  end

  private

  # Cache accessible group IDs on the user to avoid repeated queries
  # when checking multiple workflows for the same user
  def cached_accessible_group_ids(user)
    user.instance_variable_get(:@_accessible_group_ids) ||
      user.instance_variable_set(:@_accessible_group_ids, Group.accessible_group_ids_for(user))
  end

  # Check if workflow belongs to any of the given group IDs,
  # using in-memory check when associations are eager-loaded
  def workflow_in_groups?(accessible_group_ids)
    if group_workflows.loaded?
      accessible_set = accessible_group_ids.is_a?(Set) ? accessible_group_ids : accessible_group_ids.to_set
      group_workflows.any? { |gw| accessible_set.include?(gw.group_id) }
    else
      groups.where(id: accessible_group_ids).any?
    end
  end

  # Check if workflow has no groups, using in-memory check when loaded
  def workflow_has_no_groups?
    if group_workflows.loaded?
      group_workflows.empty?
    else
      groups.empty?
    end
  end
end
