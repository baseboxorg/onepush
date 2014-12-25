task :create_app_user => :install_essentials do
  log_notice "Creating user account for app..."
  on roles(:app) do |host|
    name = APP_CONFIG.user

    if !test("id -u #{name} >/dev/null 2>&1")
      create_user(host, name)
    end
    case APP_CONFIG.type
    when 'ruby'
      case APP_CONFIG.ruby_manager
      when 'rvm'
        sudo(host, "usermod -a -G rvm #{name}")
      end
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
  end
end

task :create_app_vhost => [:create_app_dir] do
  log_notice "Creating web server virtual host for app..."
  app_dir = APP_CONFIG.app_dir
  user    = APP_CONFIG.user
  shared_dir = "#{app_dir}/shared"
  local_conf = "#{shared_dir}/config/nginx-vhost-local.conf"

  if APP_CONFIG.type == 'ruby' && APP_CONFIG.ruby_manager == 'rvm'
    ruby_version = APP_CONFIG.ruby_version || 'default'
    script = StringIO.new
    script.puts "#!/bin/bash"
    script.puts "# Installed by #{POMODORI_APP_NAME}."
    script.puts "exec /usr/local/rvm/bin/rvm-exec #{ruby_version} ruby \"$@\""
    script.rewind
  end

  config = StringIO.new
  config.puts "# Autogenerated by #{POMODORI_APP_NAME}. Do not edit. " +
    "Changes will be overwritten. Edit nginx-vhost-local.conf instead."
  config.puts "server {"
  config.puts "    listen 80;"
  config.puts "    server_name #{APP_CONFIG.domain_names};"
  config.puts "    root #{app_dir}/current/public;"
  config.puts "    passenger_enabled on;"
  if APP_CONFIG.type == 'ruby' && APP_CONFIG.ruby_manager == 'rvm'
    config.puts "    passenger_ruby #{shared_dir}/ruby;"
  end
  config.puts "    passenger_user #{user};"
  config.puts "    include #{local_conf};"
  config.puts "}"
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
