require "../log"

require "placeos-models"
require "placeos-models/spec/generator"
require "uuid"

module PlaceOS::Tasks::Entities
  extend self
  Log = ::Log.for(self)

  def create_authority(
    name : String,
    domain : String,
    config : Hash(String, JSON::Any)
  )
    upsert_document(Model::Authority.find_by_domain(domain)) do
      Log.info { {message: "creating Authority", name: name, domain: domain} }
      auth = Model::Authority.new
      auth.name = File.join(domain.lchop("https://").lchop("http://"), name)
      auth.domain = domain
      auth.config = config
      auth
    end
  rescue e
    log_fail("Authority", e)
    raise e
  end

  def create_interface(
    name : String,
    folder_name : String,
    description : String,
    uri : String,
    branch : String = "master",
    commit_hash : String = "HEAD"
  )
    upsert_document(Model::Repository.where(
      repo_type: Model::Repository::Type::Interface,
      folder_name: folder_name.strip.downcase)
    ) do
      Log.info { {
        message:     "creating Interface Repository",
        folder_name: folder_name,
        name:        name,
        branch:      branch,
        commit_hash: commit_hash,
        uri:         uri,
      } }

      frontend = Model::Repository.new
      frontend.repo_type = Model::Repository::Type::Interface
      frontend.branch = branch
      frontend.commit_hash = commit_hash
      frontend.description = description
      frontend.folder_name = folder_name
      frontend.name = name
      frontend.uri = uri
      frontend
    end
  rescue e
    log_fail("Interface Repository", e)
    raise e
  end

  def create_user(
    authority : Model::Authority | String,
    name : String? = nil,
    email : String? = nil,
    password : String? = nil,
    sys_admin : Bool = false,
    support : Bool = false
  )
    authority = Model::Authority.find!(authority) if authority.is_a?(String)
    name = "PlaceOS Support (#{authority.name})" if name.nil?
    email = "support@place.tech" if email.nil?
    authority_id = authority.id.as(String)

    upsert_document(Model::User.find_by_email(authority_id, email)) do
      Log.info { {message: "Creating admin user", email: email, site_name: authority.name, authority_id: authority.id} }
      if password.nil? || password.empty?
        password = secure_string(bytes: 8)
        Log.warn { {message: "temporary password generated for #{email} (#{name}). change it ASAP.", password: password} }
      end
      user = Model::User.new
      user.name = name
      user.sys_admin = sys_admin
      user.support = support
      user.authority_id = authority_id
      user.email = email
      user.password = password
      user
    end
  rescue e
    log_fail("Admin user", e)
    raise e
  end

  def create_application(
    authority : Model::Authority | String,
    name : String,
    base : String,
    redirect_uri : String? = nil,
    scope : String? = nil
  )
    authority = Model::Authority.find!(authority) if authority.is_a?(String)
    authority_id = authority.id.as(String)

    redirect_uri = File.join(base, name, "oauth-resp.html") if redirect_uri.nil?
    application_id = Digest::MD5.hexdigest(redirect_uri)
    scope = "public" if scope.nil? || scope.empty?

    upsert_document(Model::DoorkeeperApplication.get_all([application_id], index: :uid)) do
      Log.info { {
        message:      "creating Application",
        name:         name,
        base:         base,
        scope:        scope,
        redirect_uri: redirect_uri,
      } }
      application = Model::DoorkeeperApplication.new

      # Required as we are setting a custom database id
      application._new_flag = true

      application.name = name
      application.secret = secure_string(bytes: 48)
      application.redirect_uri = redirect_uri
      application.id = application_id
      application.uid = application_id
      application.scopes = scope
      application.skip_authorization = true
      application.owner_id = authority_id
      application
    end
  rescue e
    log_fail("Application", e)
    raise e
  end

  def create_placeholders
    version = UUID.random.to_s.split('-').first

    private_repository_uri = "https://github.com/placeos/private-drivers"
    private_repository_name = "Private Drivers"
    private_repository_folder_name = "private-drivers"

    private_repository = upsert_document(Model::Repository.where(
      uri: private_repository_uri,
      name: private_repository_name,
      folder_name: private_repository_folder_name,
    )) do
      repo = Model::Generator.repository(type: Model::Repository::Type::Driver)
      repo.uri = private_repository_uri
      repo.name = private_repository_name
      repo.folder_name = private_repository_folder_name
      repo.description = "PlaceOS Private Drivers"
      repo
    end

    drivers_repository_uri = "https://github.com/placeos/drivers"
    drivers_repository_name = "Drivers"
    drivers_repository_folder_name = "drivers"

    upsert_document(Model::Repository.where(
      uri: drivers_repository_uri,
      name: drivers_repository_name,
      folder_name: drivers_repository_folder_name,
    )) do
      repo = Model::Generator.repository(type: Model::Repository::Type::Driver)
      repo.uri = drivers_repository_uri
      repo.name = drivers_repository_name
      repo.folder_name = drivers_repository_folder_name
      repo.description = "PlaceOS Drivers"
      repo
    end

    driver = upsert_document(Model::Driver.all) do
      driver_file_name = "drivers/place/private_helper.cr"
      driver_module_name = "PrivateHelper"
      driver_name = "spec_helper"
      driver_role = Model::Driver::Role::Logic
      new_driver = Model::Driver.new(
        name: driver_name,
        role: driver_role,
        commit: "HEAD",
        module_name: driver_module_name,
        file_name: driver_file_name,
      )

      new_driver.repository = private_repository
      new_driver
    end

    zone = upsert_document(Model::Zone.all) do
      zone_name = "TestZone-#{version}"
      new_zone = Model::Zone.new(name: zone_name)
      new_zone
    end

    control_system = upsert_document(Model::ControlSystem.all) do
      # ControlSystem metadata
      control_system_name = "TestSystem-#{version}"
      new_control_system = Model::ControlSystem.new(name: control_system_name)
      new_control_system
    end

    upsert_document(Model::Settings.for_parent(control_system.id.as(String))) do
      settings_string = %(test_setting: true)
      settings_encryption_level = Encryption::Level::None
      settings = Model::Settings.new(encryption_level: settings_encryption_level, settings_string: settings_string)
      settings.control_system = control_system
      settings
    end

    mod = upsert_document(Model::Module.where(driver_id: driver.id.as(String), control_system_id: control_system.id.as(String))) do
      module_name = "TestModule-#{version}"
      new_module = Model::Generator.module(driver: driver, control_system: control_system)
      new_module.custom_name = module_name
      new_module
    end

    # Update subarrays of ControlSystem
    control_system.add_module(mod.id.as(String))
    control_system.zones = control_system.zones.as(Array(String)) | [zone.id.as(String)]
    control_system.save!

    trigger = upsert_document(Model::Trigger.where(control_system_id: control_system.id.as(String))) do
      # Trigger metadata
      trigger_name = "TestTrigger-#{version}"
      trigger_description = "a test trigger"
      new_trigger = Model::Trigger.new(name: trigger_name, description: trigger_description)
      new_trigger.control_system = control_system
      new_trigger
    end

    upsert_document(Model::TriggerInstance.of(trigger.id.as(String))) do
      trigger_instance = Model::TriggerInstance.new
      trigger_instance.control_system = control_system
      trigger_instance.zone = zone
      trigger_instance.trigger = trigger
      trigger_instance
    end

    upsert_document(Model::Edge.all) do
      Model::Edge.new(
        name: "TestEdge-#{version}",
        description: "Automatically generated edge profile. Set PLACE_EDGE_SECRET in your edge node's",
      )
    end
  rescue e
    log_fail("Placeholder", e)
    raise e
  end

  protected def upsert_document(query)
    existing = query.is_a?(Iterator) || query.is_a?(Enumerable) ? query.first? : query
    if existing.nil?
      model = yield
      model.save!
      Log.info { "created #{model.class}<#{model.id}>" }
      model
    else
      Log.info { "using existing #{existing.class}<#{existing.id}>" }
      existing
    end
  end

  private def log_fail(type : String, exception : Exception)
    Log.error(exception: exception) {
      Log.context.set(model: exception.model.class.name, model_errors: exception.errors) if exception.is_a?(RethinkORM::Error::DocumentInvalid)
      "#{type} creation failed with: #{exception.inspect_with_backtrace}"
    }
  end

  private def secure_string(bytes : Int32)
    Random::Secure.hex(bytes)
  end
end
