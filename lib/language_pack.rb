require "pathname"

# General Language Pack module
module LanguagePack

  # detects which language pack to use
  # @param [Array] first argument is a String of the build directory
  # @return [LanguagePack] the {LanguagePack} detected
  def self.detect(*args)
    Dir.chdir(args.first)

    pack = [NoLockfile, Rack].detect do |klass|
      klass.use?
    end

    pack ? pack.new(*args) : nil
  end

end

require "language_pack/rack"
require "language_pack/no_lockfile"

# require "language_pack/ruby"
# require "language_pack/rails2"
# require "language_pack/rails3"
# require "language_pack/disable_deploys"
# require "language_pack/rails4"
