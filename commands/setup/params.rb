require_relative '../../lib/app_config'
require_relative '../../lib/infrastructure_config'
require_relative '../../lib/database_config'

module Pomodori
  module Commands
    class SetupParams < Pomodori::InfrastructureConfig
      RESETUP_PROPERTIES = %w(
        external_database
      ).freeze

      property :app_config, Pomodori::AppConfig

      property :server_address, String
      property :app_server_addresses, Array[String], default: []
      property :db_server_address, String
      property :external_database, DatabaseConfig

      property :if_needed, BooleanValue, default: false
      property :ssh_log, String
      property :ssh_keys, Array[String], default: []
      property :vagrant_key, String
      property :progress, BooleanValue, default: false
      property :progress_base, Float, default: 0
      property :progress_ceil, Float, default: 1

      property :install_passenger, BooleanValue, default: true
      property :force_install_passenger_from_source, BooleanValue, default: false
      property :install_web_server, BooleanValue, default: true
      property :install_common_ruby_app_dependencies, BooleanValue, default: true

      def install_database?
        external_database.nil?
      end

      def validate_and_finalize!
        if app_config.nil?
          abort "The parameter 'app_config' is required."
        end

        if server_address
          if app_server_addresses.any? || db_server_address
            abort "When the 'server_address' parameter is set, " +
              "'app_server_addresses' and 'db_server_address' may not be set."
          end
          self.app_server_addresses = [server_address]
          self.db_server_address = server_address
          self.server_address = nil
        else
          if app_server_addresses.empty?
            abort "The parameter 'app_server_addresses' is required."
          end
          if db_server_address.nil? && external_database.nil?
            abort "The parameter 'db_server_address' is required."
          end
        end

        if external_database && db_server_address
          abort "When the 'external_database' parameter is set, " +
            "'server_address' and 'db_server_address' may not be set."
        end

        if external_database
          external_database.validate_and_finalize!(app_config)
        end
      end
    end
  end
end
