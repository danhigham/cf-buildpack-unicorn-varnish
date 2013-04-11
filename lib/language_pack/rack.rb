require "language_pack"
require "language_pack/ruby"
require "language_pack/http_client"

# Rack Language Pack. This is for any non-Rails Rack apps like Sinatra.
class LanguagePack::Rack < LanguagePack::Ruby
  include LanguagePack::HTTPClient

  # detects if this is a valid Rack app by seeing if "config.ru" exists
  # @return [Boolean] true if it's a Rack app
  def self.use?
    LanguagePack::Ruby.gem_version('rack') && LanguagePack::Ruby.gem_version('unicorn')
  end

  def name
    "Ruby/Rack"
  end

  def compile
    install_varnish

    super
    # write_unicorn_config
  end

  def default_config_vars
    super.merge({
      "RACK_ENV" => "production"
    })
  end

  def default_process_types
    # let's special case thin here if we detect it
    # web_process = "bundle exec unicorn -p $PORT"
    web_process = "/app/bin/varnishd -a 0.0.0.0:$PORT -d -n ../varnish_tmp"

    super.merge({
      "web" => web_process
    })
  end

private

  def install_varnish
    Dir.chdir(build_path)

    topic("Installing Varnish")

    varnish_asset_url = "http://s3-eu-west-1.amazonaws.com/buildpack-assets/varnish-3.0.3-bin.tgz"
    varnish_archive = './varnish.tgz'

    download(varnish_asset_url, varnish_archive)
    run("tar zxf #{varnish_archive}")

    bin_dir = "bin"
    FileUtils.mkdir_p bin_dir

    tmp_dir = "varnish_tmp"
    FileUtils.mkdir_p tmp_dir


    Dir["./varnish/*"].each do |bin|
      puts bin
      run("ln -s #{bin} ./#{bin_dir}/")
    end

    run("rm #{varnish_archive}")

  end

  def write_unicorn_config

  end

  # sets up the profile.d script for this buildpack
  def setup_profiled
    super
    set_env_default "RACK_ENV", "production"
  end

end

