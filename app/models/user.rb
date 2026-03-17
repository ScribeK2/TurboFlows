class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :lockable, :timeoutable

  has_many :workflows, dependent: :destroy
  has_many :scenarios, dependent: :destroy
  has_many :user_groups, dependent: :destroy
  has_many :groups, through: :user_groups

  # String-backed enum — maps to existing column values with no migration needed.
  # :regular maps to DB value "user" to avoid User.user naming collision.
  enum :role, { admin: "admin", editor: "editor", regular: "user" }, default: "user"

  # -- Scopes for admin filtering --
  scope :search_by, lambda { |query|
    return all if query.blank?

    search_term = "%#{sanitize_sql_like(query)}%"
    case_insensitive_like("email", search_term)
      .or(case_insensitive_like("display_name", search_term))
  }

  scope :by_role, lambda { |role|
    where(role: role)
  }

  scope :by_group, lambda { |group_id|
    joins(:user_groups).where(user_groups: { group_id: group_id }).distinct
  }

  scope :sorted_by, lambda { |field|
    case field
    when "email_asc"      then order(email: :asc)
    when "email_desc"     then order(email: :desc)
    when "role_asc"       then order(role: :asc)
    when "created_at_asc" then order(created_at: :asc)
    else                       order(created_at: :desc)
    end
  }

  # Keep ROLES for backward compatibility with any code referencing it
  ROLES = %w[admin editor user].freeze

  normalizes :display_name, with: ->(name) { name.strip }

  # Validations
  validates :display_name, length: { maximum: 50 }, allow_blank: true

  # Check if user can create workflows
  def can_create_workflows?
    admin? || editor?
  end

  # Check if user can edit workflows
  def can_edit_workflows?
    admin? || editor?
  end

  # Check if user can manage templates
  def can_manage_templates?
    admin?
  end

  # Check if user can access admin panel
  def can_access_admin?
    admin?
  end

  # Get groups accessible to this user (admins see all, others see assigned groups)
  def accessible_groups
    admin? ? Group.all : groups
  end

  # Preferred label for displaying the user in the UI
  def display_label
    display_name.presence || email
  end

  # Avatar display helpers
  def avatar_initial
    display_label[0].upcase
  end

  AVATAR_COLORS = {
    'admin' => 'avatar--admin',
    'editor' => 'avatar--editor',
    'regular' => 'avatar--regular'
  }.freeze

  AVATAR_BADGE_CLASSES = {
    'admin' => 'badge--admin',
    'editor' => 'badge--editor',
    'regular' => 'badge--regular'
  }.freeze

  def avatar_color_class
    AVATAR_COLORS[role] || AVATAR_COLORS['regular']
  end

  def avatar_role_badge_classes
    AVATAR_BADGE_CLASSES[role] || AVATAR_BADGE_CLASSES['regular']
  end

  # When true, Devise will not send the "password changed" email (used for admin
  # temporary password resets where the password is shown in the UI instead).
  attr_accessor :skip_password_change_notification

  # Skip password-change email when set by admin reset (avoids SMTP in environments
  # where mail is not configured, e.g. Render without SendGrid).
  def send_password_change_notification
    return if skip_password_change_notification

    super
  end

  # Generate a secure temporary password for admin reset
  def generate_temporary_password
    self.skip_password_change_notification = true
    temp_password = SecureRandom.alphanumeric(14) + SecureRandom.random_number(10).to_s + ("A".."Z").to_a.sample
    temp_password = temp_password.chars.shuffle.join
    self.password = temp_password
    self.password_confirmation = temp_password
    save!(validate: false)
    temp_password
  end
end
