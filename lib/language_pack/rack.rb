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
    super
    # install_varnish
    # write_unicorn_config
  end

  def default_config_vars
    super.merge({
      "RACK_ENV" => "production"
    })
  end

  def default_process_types
    # let's special case thin here if we detect it
    web_process = "bundle exec unicorn -p $PORT"

    super.merge({
      "web" => web_process
    })
  end

private

  def install_varnish
    topic("Installing Varnish")

    varnish_asset_url = "http://s3-eu-west-1.amazonaws.com/buildpack-assets/varnish-3.0.3-bin.tgz"
    varnish_archive = './varnish.tgz'

    download(varnish_asset_url, varnish_archive)
    run("tar zxf #{varnish_archive}")

    bin_dir = "bin"
    FileUtils.mkdir_p bin_dir

    Dir["./varnish/*"].each do |bin|
      puts bin
      # run("ln -s #{bin} #{bin_dir}")
    end

  end

  def write_unicorn_config

  end

  # sets up the profile.d script for this buildpack
  def setup_profiled
    super
    set_env_default "RACK_ENV", "production"
  end

end

