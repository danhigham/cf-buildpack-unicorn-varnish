require "tmpdir"
require "rubygems"
require "language_pack"
require "language_pack/base"
require "language_pack/bundler_lockfile"
require "language_pack/blobstore_client"

# base Ruby Language Pack. This is for any base ruby app.
class LanguagePack::Ruby < LanguagePack::Base
  include LanguagePack::BlobstoreClient
  include LanguagePack::BundlerLockfile
  extend LanguagePack::BundlerLockfile

  BUILDPACK_VERSION   = "v52"
  LIBYAML_VERSION     = "0.1.4"
  LIBYAML_PATH        = "libyaml-#{LIBYAML_VERSION}"
  BUNDLER_VERSION     = "1.3.0.pre.5"
  BUNDLER_GEM_PATH    = "bundler-#{BUNDLER_VERSION}"
  NODE_VERSION        = "0.4.7"
  NODE_JS_BINARY_PATH = "node-#{NODE_VERSION}"
  JVM_BASE_URL        = "http://heroku-jvm-langpack-java.s3.amazonaws.com"
  JVM_VERSION         = "openjdk7-latest"
  DEFAULT_RUBY_VERSION = "ruby-1.9.2"
  BLOB_IDS = {"ruby-1.9.2" => {:oid => "4e4e78bca31e122204e4e9863b1b740510096a2b8696", :sig => "/45mjMKhckPxTUhNBeexTFAALA4=",
                               :sha => "84134cbc0e3345244a039c8cb43fdbb056bc2d34"},
              "ruby-1.9.3" => {:oid => "4e4e78bca61e121004e4e7d51d950e0510096a910e5a", :sig => "+1Tod4mmEt4BG9j/1C6rYy6x4kw=",
                               :sha => "9160b6a5b1e66ad9bcd0f200b8be15e91d16c7c7"},
              "ruby-1.8.7" => {:oid => "4e4e78bca21e122004e4e8ec647a54051009649e5732", :sig => "Pz/1y7YFwlsPcIaRte7RO79RSNo=",
                               :sha => "d59f166a28a130c6b89665efed10a7273716e981"},
              "ruby-build-1.8.7" => {:oid => "4e4e78bca41e121204e4e86ee539210510096aee7893", :sig => "LVHbg6vNJh9cXzHb8bUBRDiJ09w=",
                                     :sha => "70b291a400233d5076dd9fd7969570e164c6c484"},
              "ruby-build-1.9.2" => {:oid => "4e4e78bca21e122204e4e9863926b10510096b389b02", :sig => "HZ+96UdoJr324YZHcAcSjwkMq2I=",
                                     :sha => "6f17cd95878781334be656460ef4873f57c88643"}}

  # detects if this is a valid Ruby app
  # @return [Boolean] true if it's a Ruby app
  def self.use?
    File.exist?("Gemfile")
  end

  def self.lockfile_parser
    require "bundler"
    Bundler::LockfileParser.new(File.read("Gemfile.lock"))
  end

  def self.gem_version(name)
    gem_version = nil
    bootstrap_bundler do |bundler_path|
      $: << "#{bundler_path}/gems/bundler-#{LanguagePack::Ruby::BUNDLER_VERSION}/lib"
      gem         = lockfile_parser.specs.detect {|gem| gem.name == name }
      gem_version = gem.version if gem
    end

    gem_version
  end

  def name
    "Ruby"
  end

  def default_addons
    add_dev_database_addon
  end

  def default_config_vars
    vars = {
      "LANG"     => "en_US.UTF-8",
      "PATH"     => default_path,
      "GEM_PATH" => slug_vendor_base,
    }

    ruby_version_jruby? ? vars.merge("JAVA_OPTS" => default_java_opts, "JRUBY_OPTS" => default_jruby_opts) : vars
  end

  def default_process_types
    {
      "rake"    => "bundle exec rake",
      "console" => "bundle exec irb"
    }
  end

  def compile
    staging_environment_path # Save current environment path first
    Dir.chdir(build_path)
    remove_vendor_bundle
    install_ruby
    install_jvm
    setup_language_pack_environment
    setup_profiled
    allow_git do
      install_language_pack_gems
      build_bundler
      create_database_yml
      install_binaries
      run_assets_precompile_rake_task
    end
  end

private

  # the base PATH environment variable to be used
  # @return [String] the resulting PATH
  def default_path
    "bin:#{slug_vendor_base}/bin:/usr/local/bin:/usr/bin:/bin"
  end

  def staging_environment_path
    @staging_environment_path ||= ENV["PATH"]
  end

  # the relative path to the bundler directory of gems
  # @return [String] resulting path
  def slug_vendor_base
    if @slug_vendor_base
      @slug_vendor_base
    elsif @ruby_version == "ruby-1.8.7"
      @slug_vendor_base = "vendor/bundle/1.8"
    else
      @slug_vendor_base = run(%q(ruby -e "require 'rbconfig';puts \"vendor/bundle/#{RUBY_ENGINE}/#{RbConfig::CONFIG['ruby_version']}\"")).chomp
    end
  end

  # the relative path to the vendored ruby directory
  # @return [String] resulting path
  def slug_vendor_ruby
    "vendor/#{ruby_version}"
  end

  # the relative path to the vendored jvm
  # @return [String] resulting path
  def slug_vendor_jvm
    "vendor/jvm"
  end

  # the absolute path of the build ruby to use during the buildpack
  # @return [String] resulting path
  def build_ruby_path
    "/tmp/#{ruby_version}"
  end

  # fetch the ruby version from bundler
  # @return [String, nil] returns the ruby version if detected or nil if none is detected
  def ruby_version
    return @ruby_version if @ruby_version_run

    @ruby_version_run = true

    bootstrap_bundler do |bundler_path|
      old_system_path = "/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
      @ruby_version = run_stdout("env PATH=#{old_system_path}:#{bundler_path}/bin:$PATH GEM_PATH=#{bundler_path} bundle platform --ruby").chomp
    end

    if @ruby_version == "No ruby version specified" && ENV['RUBY_VERSION']
      # for backwards compatibility.
      # this will go away in the future
      @ruby_version = ENV['RUBY_VERSION']
      @ruby_version_env_var = true
    elsif @ruby_version == "No ruby version specified"
      @ruby_version = DEFAULT_RUBY_VERSION
    else
      @ruby_version = @ruby_version.sub('(', '').sub(')', '').split.join('-')
      @ruby_version_env_var = false
    end

    @ruby_version
  end

  # determine if we're using rbx
  # @return [Boolean] true if we are and false if we aren't
  def ruby_version_rbx?
    ruby_version ? ruby_version.match(/rbx-/) : false
  end

  # determine if we're using jruby
  # @return [Boolean] true if we are and false if we aren't
  def ruby_version_jruby?
    @ruby_version_jruby ||= ruby_version ? ruby_version.match(/jruby-/) : false
  end

  # default JAVA_OPTS
  # return [String] string of JAVA_OPTS
  def default_java_opts
    "-Xmx384m -Xss512k -XX:+UseCompressedOops -Dfile.encoding=UTF-8"
  end

  # default JRUBY_OPTS
  # return [String] string of JRUBY_OPTS
  def default_jruby_opts
    "-Xcompile.invokedynamic=true"
  end

  # list the available valid ruby versions
  # @note the value is memoized
  # @return [Array] list of Strings of the ruby versions available
  def ruby_versions
    BLOB_IDS.keys
  end

  # sets up the environment variables for the build process
  def setup_language_pack_environment
    setup_ruby_install_env

    config_vars = default_config_vars.each do |key, value|
      ENV[key] ||= value
    end
    ENV["GEM_HOME"] = slug_vendor_base
    ENV["GEM_PATH"] = slug_vendor_base
    ENV["PATH"]     = "#{ruby_install_binstub_path}:#{config_vars["PATH"]}:#{staging_environment_path}"
  end

  # sets up the profile.d script for this buildpack
  def setup_profiled
    set_env_override "GEM_PATH", "$HOME/#{slug_vendor_base}:$GEM_PATH"
    set_env_default  "LANG",     "en_US.UTF-8"
    set_env_override "PATH",     "$HOME/bin:$HOME/#{slug_vendor_base}/bin:#{staging_environment_path}:$PATH"

    if ruby_version_jruby?
      set_env_default "JAVA_OPTS", default_java_opts
      set_env_default "JRUBY_OPTS", default_jruby_opts
    end
  end

  # determines if a build ruby is required
  # @return [Boolean] true if a build ruby is required
  def build_ruby?
    @build_ruby ||= !ruby_version_rbx? && !ruby_version_jruby? && !%w{ruby-1.9.3 ruby-2.0.0}.include?(ruby_version)
  end

  # install the vendored ruby
  # @return [Boolean] true if it installs the vendored ruby and false otherwise
  def install_ruby
    return false unless ruby_version

    invalid_ruby_version_message = <<ERROR
Invalid RUBY_VERSION specified: #{ruby_version}
Valid versions: #{ruby_versions.join(", ")}
ERROR

    if build_ruby?
      FileUtils.mkdir_p(build_ruby_path)
      Dir.chdir(build_ruby_path) do
        ruby_vm = ruby_version_rbx? ? "rbx" : "ruby"
        ruby_name = ruby_version.sub(ruby_vm, "#{ruby_vm}-build")
        ruby_filename = "#{ruby_name}.tgz"
        download_blob(BLOB_IDS[ruby_name][:oid], BLOB_IDS[ruby_name][:sig], BLOB_IDS[ruby_name][:sha], ruby_filename )
        run("tar zxf #{ruby_filename}")
      end
      error invalid_ruby_version_message unless $?.success?
    end

    FileUtils.mkdir_p(slug_vendor_ruby)
    Dir.chdir(slug_vendor_ruby) do
      ruby_filename = "#{ruby_version}.tgz"
      download_blob(BLOB_IDS[ruby_version][:oid], BLOB_IDS[ruby_version][:sig], BLOB_IDS[ruby_version][:sha], ruby_filename )
      run("tar zxf #{ruby_filename}")
    end
    error invalid_ruby_version_message unless $?.success?

    bin_dir = "bin"
    FileUtils.mkdir_p bin_dir
    Dir["#{slug_vendor_ruby}/bin/*"].each do |bin|
      run("ln -s ../#{bin} #{bin_dir}")
    end

    if !@ruby_version_env_var
      topic "Using Ruby version: #{ruby_version}"
    else
      topic "Using RUBY_VERSION: #{ruby_version}"
      puts  "WARNING: RUBY_VERSION support has been deprecated and will be removed entirely on August 1, 2012."
      puts  "See https://devcenter.heroku.com/articles/ruby-versions#selecting_a_version_of_ruby for more information."
    end

    true
  end

  # vendors JVM into the slug for JRuby
  def install_jvm
    if ruby_version_jruby?
      topic "Installing JVM: #{JVM_VERSION}"

      FileUtils.mkdir_p(slug_vendor_jvm)
      Dir.chdir(slug_vendor_jvm) do
        run("curl #{JVM_BASE_URL}/#{JVM_VERSION}.tar.gz -s -o - | tar xzf -")
      end

      bin_dir = "bin"
      FileUtils.mkdir_p bin_dir
      Dir["#{slug_vendor_jvm}/bin/*"].each do |bin|
        run("ln -s ../#{bin} #{bin_dir}")
      end
    end
  end

  # find the ruby install path for its binstubs during build
  # @return [String] resulting path or empty string if ruby is not vendored
  def ruby_install_binstub_path
    @ruby_install_binstub_path ||=
      if build_ruby?
        "#{build_ruby_path}/bin"
      elsif ruby_version
        "#{slug_vendor_ruby}/bin"
      else
        ""
      end
  end

  # setup the environment so we can use the vendored ruby
  def setup_ruby_install_env
    ENV["PATH"] = "#{ruby_install_binstub_path}:#{ENV["PATH"]}"

    if ruby_version_jruby?
      ENV['JAVA_OPTS']  = default_java_opts
    end
  end

  # list of default gems to vendor into the slug
  # @return [Array] resulting list of gems
  def gems
    [BUNDLER_GEM_PATH]
  end

  # installs vendored gems into the slug
  def install_language_pack_gems
    FileUtils.mkdir_p(slug_vendor_base)
    Dir.chdir(slug_vendor_base) do |dir|
      gems.each do |gem|
        run("curl #{VENDOR_URL}/#{gem}.tgz -s -o - | tar xzf -")
      end
      Dir["bin/*"].each {|path| run("chmod 755 #{path}") }
    end
  end

  # default set of binaries to install
  # @return [Array] resulting list
  def binaries
    add_node_js_binary
  end

  # vendors binaries into the slug
  def install_binaries
    binaries.each {|binary| install_binary(binary) }
    Dir["bin/*"].each {|path| run("chmod +x #{path}") }
  end

  # vendors individual binary into the slug
  # @param [String] name of the binary package from S3.
  #   Example: https://s3.amazonaws.com/language-pack-ruby/node-0.4.7.tgz, where name is "node-0.4.7"
  def install_binary(name)
    bin_dir = "bin"
    FileUtils.mkdir_p bin_dir
    Dir.chdir(bin_dir) do |dir|
      run("curl #{VENDOR_URL}/#{name}.tgz -s -o - | tar xzf -")
    end
  end

  # removes a binary from the slug
  # @param [String] relative path of the binary on the slug
  def uninstall_binary(path)
    FileUtils.rm File.join('bin', File.basename(path)), :force => true
  end

  # install libyaml into the LP to be referenced for psych compilation
  # @param [String] tmpdir to store the libyaml files
  def install_libyaml(dir)
    FileUtils.mkdir_p dir
    Dir.chdir(dir) do |dir|
      run("curl #{VENDOR_URL}/#{LIBYAML_PATH}.tgz -s -o - | tar xzf -")
    end
  end

  # remove `vendor/bundle` that comes from the git repo
  # in case there are native ext.
  # users should be using `bundle pack` instead.
  # https://github.com/heroku/heroku-buildpack-ruby/issues/21
  def remove_vendor_bundle
    if File.exists?("vendor/bundle")
      topic "WARNING:  Removing `vendor/bundle`."
      puts  "Checking in `vendor/bundle` is not supported. Please remove this directory"
      puts  "and add it to your .gitignore. To vendor your gems with Bundler, use"
      puts  "`bundle pack` instead."
      FileUtils.rm_rf("vendor/bundle")
    end
  end

  # runs bundler to install the dependencies
  def build_bundler
    log("bundle") do
      bundle_without = ENV["BUNDLE_WITHOUT"] || "development:test"
      bundle_command = "bundle install --without #{bundle_without} --path vendor/bundle --binstubs vendor/bundle/bin"

      unless File.exist?("Gemfile.lock")
        error "Gemfile.lock is required. Please run \"bundle install\" locally\nand commit your Gemfile.lock."
      end

      if has_windows_gemfile_lock?
        topic "WARNING: Removing `Gemfile.lock` because it was generated on Windows."
        puts "Bundler will do a full resolve so native gems are handled properly."
        puts "This may result in unexpected gem versions being used in your app."

        log("bundle", "has_windows_gemfile_lock")
        File.unlink("Gemfile.lock")
      else
        # using --deployment is preferred if we can
        bundle_command += " --deployment"
        cache_load ".bundle"
      end

      version = run("env RUBYOPT=\"#{syck_hack}\" bundle version").strip
      topic("Installing dependencies using #{version}")

      load_bundler_cache

      bundler_output = ""
      Dir.mktmpdir("libyaml-") do |tmpdir|
        libyaml_dir = "#{tmpdir}/#{LIBYAML_PATH}"
        install_libyaml(libyaml_dir)

        # need to setup compile environment for the psych gem
        yaml_include   = File.expand_path("#{libyaml_dir}/include")
        yaml_lib       = File.expand_path("#{libyaml_dir}/lib")
        pwd            = run("pwd").chomp
        # we need to set BUNDLE_CONFIG and BUNDLE_GEMFILE for
        # codon since it uses bundler.
        env_vars       = "env BUNDLE_GEMFILE=#{pwd}/Gemfile BUNDLE_CONFIG=#{pwd}/.bundle/config CPATH=#{yaml_include}:$CPATH CPPATH=#{yaml_include}:$CPPATH LIBRARY_PATH=#{yaml_lib}:$LIBRARY_PATH RUBYOPT=\"#{syck_hack}\""
        puts "Running: #{bundle_command}"
        bundler_output << pipe("#{env_vars} #{bundle_command} --no-clean 2>&1")

      end

      if $?.success?
        log "bundle", :status => "success"
        puts "Cleaning up the bundler cache."
        pipe "bundle clean"
        cache_store ".bundle"
        cache_store "vendor/bundle"

        # Keep gem cache out of the slug
        FileUtils.rm_rf("#{slug_vendor_base}/cache")

        # symlink binstubs
        bin_dir = "bin"
        FileUtils.mkdir_p bin_dir
        Dir["#{slug_vendor_base}/bin/*"].each do |bin|
          run("ln -s ../#{bin} #{bin_dir}") unless File.exist?("#{bin_dir}/#{bin}")
        end
      else
        log "bundle", :status => "failure"
        error_message = "Failed to install gems via Bundler."
        if bundler_output.match(/Installing sqlite3 \([\w.]+\) with native extensions\s+Gem::Installer::ExtensionBuildError: ERROR: Failed to build gem native extension./)
          error_message += <<ERROR


Detected sqlite3 gem which is not supported on Heroku.
http://devcenter.heroku.com/articles/how-do-i-use-sqlite3-for-development
ERROR
        end

        error error_message
      end
    end
  end

  # RUBYOPT line that requires syck_hack file
  # @return [String] require string if needed or else an empty string
  def syck_hack
    syck_hack_file = File.expand_path(File.join(File.dirname(__FILE__), "../../vendor/syck_hack"))
    ruby_version   = run('ruby -e "puts RUBY_VERSION"').chomp
    # < 1.9.3 includes syck, so we need to use the syck hack
    if Gem::Version.new(ruby_version) < Gem::Version.new("1.9.3")
      "-r#{syck_hack_file}"
    else
      ""
    end
  end

  # writes ERB based database.yml for Rails. The database.yml uses the DATABASE_URL from the environment during runtime.
  def create_database_yml
    log("create_database_yml") do
      return unless File.directory?("config")
      topic("Writing config/database.yml to read from DATABASE_URL")
      File.open("config/database.yml", "w") do |file|
        file.puts <<-DATABASE_YML
<%

require 'cgi'
require 'uri'

begin
  uri = URI.parse(ENV["DATABASE_URL"])
rescue URI::InvalidURIError
  raise "Invalid DATABASE_URL"
end

raise "No RACK_ENV or RAILS_ENV found" unless ENV["RAILS_ENV"] || ENV["RACK_ENV"]

def attribute(name, value, force_string = false)
  if value
    value_string =
      if force_string
        '"' + value + '"'
      else
        value
      end
    "\#{name}: \#{value_string}"
  else
    ""
  end
end

adapter = uri.scheme
adapter = "postgresql" if adapter == "postgres"

database = (uri.path || "").split("/")[1]

username = uri.user
password = uri.password

host = uri.host
port = uri.port

params = CGI.parse(uri.query || "")

%>

<%= ENV["RAILS_ENV"] || ENV["RACK_ENV"] %>:
  <%= attribute "adapter",  adapter %>
  <%= attribute "database", database %>
  <%= attribute "username", username %>
  <%= attribute "password", password, true %>
  <%= attribute "host",     host %>
  <%= attribute "port",     port %>

<% params.each do |key, value| %>
  <%= key %>: <%= value.first %>
<% end %>
        DATABASE_YML
      end
    end
  end

  # add bundler to the load path
  # @note it sets a flag, so the path can only be loaded once
  def add_bundler_to_load_path
    return if @bundler_loadpath
    $: << File.expand_path(Dir["#{slug_vendor_base}/gems/bundler*/lib"].first)
    @bundler_loadpath = true
  end

  # detects whether the Gemfile.lock contains the Windows platform
  # @return [Boolean] true if the Gemfile.lock was created on Windows
  def has_windows_gemfile_lock?
    lockfile_parser.platforms.detect do |platform|
      /mingw|mswin/.match(platform.os) if platform.is_a?(Gem::Platform)
    end
  end

  # detects if a gem is in the bundle.
  # @param [String] name of the gem in question
  # @return [String, nil] if it finds the gem, it will return the line from bundle show or nil if nothing is found.
  def gem_is_bundled?(gem)
    @bundler_gems ||= lockfile_parser.specs.map(&:name)
    @bundler_gems.include?(gem)
  end

  # setup the lockfile parser
  # @return [Bundler::LockfileParser] a Bundler::LockfileParser
  def lockfile_parser
    add_bundler_to_load_path
    @lockfile_parser ||= LanguagePack::Ruby.lockfile_parser
  end

  # detects if a rake task is defined in the app
  # @param [String] the task in question
  # @return [Boolean] true if the rake task is defined in the app
  def rake_task_defined?(task)
    run("env PATH=$PATH bundle exec rake #{task} --dry-run") && $?.success?
  end

  # executes the block with GIT_DIR environment variable removed since it can mess with the current working directory git thinks it's in
  # @param [block] block to be executed in the GIT_DIR free context
  def allow_git(&blk)
    git_dir = ENV.delete("GIT_DIR") # can mess with bundler
    blk.call
    ENV["GIT_DIR"] = git_dir
  end

  # decides if we need to enable the dev database addon
  # @return [Array] the database addon if the pg gem is detected or an empty Array if it isn't.
  def add_dev_database_addon
    gem_is_bundled?("pg") ? ['heroku-postgresql:dev'] : []
  end

  # decides if we need to install the node.js binary
  # @note execjs will blow up if no JS RUNTIME is detected and is loaded.
  # @return [Array] the node.js binary path if we need it or an empty Array
  def add_node_js_binary
    gem_is_bundled?('execjs') ? [NODE_JS_BINARY_PATH] : []
  end

  def run_assets_precompile_rake_task
    if rake_task_defined?("assets:precompile")
      require 'benchmark'

      topic "Running: rake assets:precompile"
      time = Benchmark.realtime { pipe("env PATH=$PATH:bin bundle exec rake assets:precompile 2>&1") }
      if $?.success?
        puts "Asset precompilation completed (#{"%.2f" % time}s)"
      end
    end
  end

  def bundler_cache
    "vendor/bundle"
  end

  def load_bundler_cache
    cache_load "vendor"

    full_ruby_version       = run(%q(ruby -v)).chomp
    heroku_metadata         = "vendor/heroku"
    ruby_version_cache      = "#{heroku_metadata}/ruby_version"
    buildpack_version_cache = "vendor/heroku/buildpack_version"

    # fix bug from v37 deploy
    if File.exists?("vendor/ruby_version")
      puts "Broken cache detected. Purging build cache."
      cache_clear("vendor")
      FileUtils.rm_rf("vendor/ruby_version")
      purge_bundler_cache
    # fix bug introduced in v38
    elsif !File.exists?(buildpack_version_cache) && File.exists?(ruby_version_cache)
      puts "Broken cache detected. Purging build cache."
      purge_bundler_cache
    elsif cache_exists?(bundler_cache) && File.exists?(ruby_version_cache) && full_ruby_version != File.read(ruby_version_cache).chomp
      puts "Ruby version change detected. Clearing bundler cache."
      puts "Old: #{File.read(ruby_version_cache).chomp}"
      puts "New: #{full_ruby_version}"
      purge_bundler_cache
    end

    FileUtils.mkdir_p(heroku_metadata)
    File.open(ruby_version_cache, 'w') do |file|
      file.puts full_ruby_version
    end
    File.open(buildpack_version_cache, 'w') do |file|
      file.puts BUILDPACK_VERSION
    end
    cache_store heroku_metadata
  end

  def purge_bundler_cache
    FileUtils.rm_rf(bundler_cache)
    cache_clear bundler_cache
    # need to reinstall language pack gems
    install_language_pack_gems
  end
end
