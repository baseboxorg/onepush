task :create_app_user => :install_essentials do
  log_notice "Creating user account for app..."
  on roles(:app) do |host|
    name = APP_CONFIG.user

    if !test("id -u #{name} >/dev/null 2>&1")
      create_user(host, name)
    end

    sudo(host, "mkdir -p /home/#{name}/.ssh")
    sudo(host, "chown #{name}: /home/#{name}/.ssh && " +
      "chmod 700 /home/#{name}/.ssh")

    keys = APP_CONFIG.deployment_ssh_keys.join("\n")
    sudo_edit_file_section(host, "/home/#{name}/.ssh/authorized_keys",
      "PHUSION POMODORI/ONEPUSH KEYS", keys, :chown => "#{name}:", :chmod => 700)
  end
end

task :create_app_dir => [:install_essentials, :create_app_user] do
  log_notice "Creating directory for app..."
  id    = PARAMS.app_id
  path  = APP_CONFIG.app_dir
  owner = APP_CONFIG.user

  primary_dirs       = "#{path} #{path}/releases #{path}/shared"
  shared_subdirs     = "#{path}/shared/config #{path}/shared/public/system #{path}/shared/public/assets"
  pomodori_repo_path = "#{path}/pomodori_repo"
  repo_dirs          = "#{path}/repo #{pomodori_repo_path}"

  on roles(:app) do |host|
    sudo(host, "mkdir -p #{primary_dirs} && chown #{owner}: #{primary_dirs} && chmod u=rwx,g=rx,o=x #{primary_dirs}")
    sudo(host, "mkdir -p #{shared_subdirs} && chown #{owner}: #{shared_subdirs}")

    sudo(host, "mkdir -p #{repo_dirs} && chown #{owner}: #{repo_dirs} && chmod u=rwx,g=,o= #{repo_dirs}")
    sudo(host, "cd #{pomodori_repo_path} && if ! [[ -e HEAD ]]; then sudo -u #{owner} git init --bare; fi")

    sudo(host, "mkdir -p /etc/pomodori/apps && " +
      "cd /etc/pomodori/apps && " +
      "rm -f #{id} && " +
      "ln -s #{path} #{id}")
  end
end

task :create_app_hosts_entry => :create_app_dir do
  log_notice "Creating /etc/hosts entry for app..."
  on roles(:app) do |host|
    apps = sudo_capture(host, "test -e /etc/pomodori/apps && ls -1 /etc/pomodori/apps").strip.split(/[\r\n]+/)
    apps.map! { |path| path.sub(/.*\//, '') }

    content = apps.map do |app_id|
      "127.0.0.1 pomodori-#{app_id}"
    end.join("\n")

    sudo_edit_file_section(host, "/etc/hosts",
      "PHUSION POMODORI/ONEPUSH APPS",
      content,
      :chmod => "644",
      :chown => "root:")
  end
end

task :create_app_vhost => :create_app_dir do
  log_notice "Creating web server virtual host for app..."
  app_dir = APP_CONFIG.app_dir
  user    = APP_CONFIG.user
  shared_dir = "#{app_dir}/shared"
  local_conf = "#{shared_dir}/config/nginx-vhost-local.conf"

  if APP_CONFIG.type == 'ruby' && APP_CONFIG.ruby_manager == 'rvm'
    ruby_version = APP_CONFIG.ruby_version || 'default'
    script = StringIO.new
    script.puts "#!/bin/bash"
    script.puts "# Installed by Phusion #{POMODORI_APP_NAME}."
    script.puts "exec /usr/local/rvm/bin/rvm-exec #{ruby_version} ruby \"$@\""
    script.rewind
  elsif APP_CONFIG.type == 'nodejs' && APP_CONFIG.nodejs_manager == 'nvm'
    nodejs_version = APP_CONFIG.nodejs_version || 'default'
    script = StringIO.new
    script.puts "#!/bin/bash"
    script.puts "# Installed by Phusion #{POMODORI_APP_NAME}."
    script.puts "source /usr/local/nvm/nvm.sh"
    script.puts "exec nvm exec #{nodejs_version} node \"$@\""
    script.rewind
  end

  config = StringIO.new
  config.puts "# Autogenerated by Phusion #{POMODORI_APP_NAME}. Do not edit. " +
    "Changes will be overwritten. Edit nginx-vhost-local.conf instead."
  config.puts "server {"
  config.puts "    listen 80;"
  config.puts "    server_name #{APP_CONFIG.domain_names} pomodori-#{PARAMS.app_id};"
  config.puts "    root #{app_dir}/current/public;"
  if APP_CONFIG.passenger
    config.puts "    passenger_enabled on;"
    if APP_CONFIG.type == 'ruby' && APP_CONFIG.ruby_manager == 'rvm'
      config.puts "    passenger_ruby #{shared_dir}/ruby;"
    elsif APP_CONFIG.type == 'nodejs' && APP_CONFIG.nodejs_manager == 'nvm'
      config.puts "    passenger_nodejs #{shared_dir}/nodejs;"
    end
    config.puts "    passenger_user #{user};"
  end
  config.puts "    include #{local_conf};"
  config.puts "}"
  if APP_CONFIG.passenger
    config.puts
    config.puts "passenger_pre_start http://pomodori-#{PARAMS.app_id}/;"
  end
  config.rewind

  local = StringIO.new
  local.puts "# You can put custom Nginx configuration here. This file will not " +
    "be overrwitten by #{POMODORI_APP_NAME}."
  local.rewind

  on roles(:app) do |host|
    if APP_CONFIG.type == 'ruby' && APP_CONFIG.ruby_manager == 'rvm'
      sudo_upload(host, script, "#{shared_dir}/ruby",
        :chown => "#{user}:",
        :chmod => "755")
    elsif APP_CONFIG.type == 'nodejs' && APP_CONFIG.nodejs_manager == 'nvm'
      sudo_upload(host, script, "#{shared_dir}/nodejs",
        :chown => "#{user}:",
        :chmod => "755")
    end

    changed = check_file_change(host, "#{app_dir}/shared/config/nginx-vhost.conf") do
      sudo_upload(host, config, "#{app_dir}/shared/config/nginx-vhost.conf",
        :chown => "#{user}:",
        :chmod => 600)
    end
    if changed
      sudo(host, "touch /var/run/pomodori/restart_web_server")
    end

    if sudo_test(host, "[[ ! -e #{local_conf} ]]")
      sudo_upload(host, local, local_conf,
        :chown => "#{user}:",
        :chmod => "640")
    end
  end
end

task :create_app_secrets => :create_app_dir do
  app_dir = APP_CONFIG.app_dir

  on roles(:app) do |host|
    if !sudo_test(host, "[[ -e #{app_dir}/shared/config/secrets.yml ]]")
      config = StringIO.new
      config.puts "# Installed by Phusion #{POMODORI_APP_NAME}."
      config.puts "default_settings: &default_settings"
      config.puts "  secret_key_base: #{SecureRandom.hex(64)}"
      config.puts
      ["development", "staging", "production"].each do |env|
        config.puts "#{env}:"
        config.puts "  <<: *default_settings"
        config.puts
      end
      config.rewind
      sudo_upload(host, config, "#{app_dir}/shared/config/secrets.yml",
        :chmod => 600,
        :chown => APP_CONFIG.user)
    end
  end
end

task :create_app_passenger_sudoers_entry => :install_essentials do
  if APP_CONFIG.passenger
    invoke :install_passenger
    log_notice "Creating sudo entry for app..."

    on roles(:app) do |host|
      passenger_config = autodetect_passenger!(host)[:config_command]
      config_file      = "/etc/sudoers.d/pomodori-#{PARAMS.app_id}"

      config = StringIO.new
      config.puts "# Installed by Phusion #{POMODORI_APP_NAME}."
      config.puts "#{APP_CONFIG.user} ALL=NOPASSWD: #{passenger_config} restart-app " +
        "--ignore-app-not-running #{APP_CONFIG.app_dir}/"
      config.puts "#{APP_CONFIG.user} ALL=NOPASSWD: #{passenger_config} restart-app " +
        "--rolling-restart --ignore-app-not-running #{APP_CONFIG.app_dir}/"
      config.rewind

      if test_cond("-e #{config_file}")
        orig = sudo_download_to_string(host, config_file)
        should_edit = orig != config.string
      else
        should_edit = true
      end

      if should_edit
        sudo_upload(host, config, config_file,
          :chmod => "440",
          :chown => "root:")
      end
    end
  end
end
