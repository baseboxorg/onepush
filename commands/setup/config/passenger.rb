task :install_passenger => :install_essentials do
  if APP_CONFIG.passenger && PARAMS.install_passenger
    log_notice "Installing Phusion Passenger application server..."
    on roles(:app) do |host|
      if passenger_installed?(host)
        check_passenger_version_supported(host)
      else
        case host.properties.fetch(:os_class)
        when :redhat
          install_passenger_from_source(host)
        when :debian
          codename = capture(b "lsb_release -c | awk '{ print $2 }'").strip
          if can_install_passenger_from_apt_repo?(codename)
            install_passenger_from_apt(host, codename)
          else
            install_passenger_from_source(host)
          end
        else
          raise "Bug"
        end
      end

      maybe_add_passenger_bindir_to_path(host)
    end
  end
end

def passenger_installed?(host)
  !!autodetect_passenger(host)
end

def check_passenger_version_supported(host)
  passenger_info = autodetect_passenger!(host)
  version = capture("#{passenger_info[:config_command]} --version").strip
  if Gem::Version.new(version) < Gem::Version.new("4.0.45")
    fatal_and_abort "Your server already has Phusion Passenger version #{version} " +
      "installed. #{POMODORI_APP_NAME} requires Passenger 4.0.45 or later, but it currently " +
      "does not support automatically upgrading Passenger. There are two things you can do:\n\n" +
      " 1. Upgrade Passenger manually. You can find upgrade instructions in the official Passenger manuals: " +
          "https://www.phusionpassenger.com/documentation\n" +
      " 2. Uninstall Passenger, so that #{POMODORI_APP_NAME} can install Passenger from scratch."
  end
end

def can_install_passenger_from_apt_repo?(codename)
  !PARAMS.force_install_passenger_from_source && passenger_apt_repo_available?(codename)
end

def passenger_apt_repo_available?(codename)
  http = Net::HTTP.new("oss-binaries.phusionpassenger.com", 443)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_PEER
  response = http.request(Net::HTTP::Head.new("/apt/passenger/dists/#{codename}/Release"))
  response.code == "200"
end

def install_passenger_from_apt(host, codename)
  if !test_cond("-e /etc/apt/sources.list.d/passenger.list")
    config = StringIO.new
    if APP_CONFIG.passenger_enterprise
      config.puts "deb https://download:#{MANIFEST['passenger_enterprise_download_token']}@" +
        "www.phusionpassenger.com/enterprise_apt #{codename} main"
    else
      config.puts "deb https://oss-binaries.phusionpassenger.com/apt/passenger #{codename} main"
    end
    config.rewind

    sudo(host, "apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 561F9B9CAC40B2F7")
    sudo_upload(host, config, "/etc/apt/sources.list.d/passenger.list")
    force_apt_get_update_next_time(host)
    apt_get_update(host)
  end

  if APP_CONFIG.passenger_enterprise
    sudo(host, "chmod 600 /etc/apt/sources.list.d/passenger.list")
    apt_get_install(host, %w(passenger-enterprise))
  else
    apt_get_install(host, %w(passenger))
  end

  clear_cache(host, :passenger)
end

def install_passenger_from_source(host)
  _install_passenger_source_dependencies(host)

  # Install Passenger.
  if !test_cond("-e /opt/passenger/current")
    mktempdir(host) do |tmpdir|
      # Download tarball and infer directory name.
      passenger_tarball_url = "https://www.phusionpassenger.com/latest_stable_tarball"
      execute("curl --fail --silent -L -o #{tmpdir}/passenger.tar.gz #{passenger_tarball_url}")
      dirname = capture("tar tzf #{tmpdir}/passenger.tar.gz | head -n 1").strip.sub(/\/$/, '')
      if dirname.empty?
        fatal_and_abort "There is something wrong with the downloaded Passenger archive."
      end

      # Extract tarball.
      sudo(host, "mkdir -p /opt/passenger && " +
        "cd /opt/passenger && " +
        "tar xzf #{tmpdir}/passenger.tar.gz && " +
        "chown -R root: #{dirname}")

      # Update symlink.
      sudo(host, "rm -f /opt/passenger/current && " +
        "cd /opt/passenger && " +
        "ln -s #{dirname} current")
    end
  end

  clear_cache(host, :passenger)
end

task :install_passenger_source_dependencies => :install_essentials do
  on roles(:app) do |host|
    _install_passenger_source_dependencies(host)
  end
end

def _install_passenger_source_dependencies(host)
  # Install a Ruby runtime for Passenger.
  if APP_CONFIG.type == 'ruby'
    # This also ensures that Rake is installed.
    _install_ruby_runtime(host)
  else
    # If the app language is not Ruby, we don't want to install a full-blown
    # Ruby runtime for apps. We just want to install a minimalist Ruby just to
    # be able to run Passenger.
    case host.properties.fetch(:os_class)
    when :redhat
      yum_install(host, %w(ruby rubygem-rake))
    when :debian
      apt_get_install(host, %w(ruby ruby-dev rake))
    else
      raise "Bug"
    end
    clear_cache(host, :ruby)
  end

  case host.properties.fetch(:os_class)
  when :redhat
    yum_install(host, %w(libcurl-devel openssl-devel zlib-devel))
  when :debian
    apt_get_install(host, %w(libcurl4-openssl-dev libssl-dev zlib1g-dev))
  else
    raise "Bug"
  end
end

def maybe_add_passenger_bindir_to_path(host)
  passenger_info = autodetect_passenger!(host)
  installed_from_system_package = passenger_info[:installed_from_system_package]
  bindir = passenger_info[:bindir]

  if !installed_from_system_package && test_cond("-e /etc/profile.d && ! -e /etc/profile.d/passenger.sh")
    io = StringIO.new
    io.puts "# Installed by #{POMODORI_APP_NAME}."
    io.puts "export PATH=$PATH:#{bindir}"
    io.rewind

    sudo_upload(host, io, "/etc/profile.d/passenger.sh")
    sudo(host, "chmod 755 /etc/profile.d/passenger.sh")
  end
end
