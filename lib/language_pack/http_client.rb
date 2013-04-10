require "language_pack"
require "net/http"
require "uri"
require "base64"

module LanguagePack::HTTPClient

  def download(url, destination_file, sha = nil)

    File.open(destination_file, 'w') do |tf|

      begin
        Net::HTTP.get_response(URI.parse(url)) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            raise "Could not fetch object, %s/%s" % [response.code, response.body]
          end

          response.read_body do |segment|
            tf.write(segment)
          end
        end
      ensure
        tf.close
      end

      if not sha.nil?
        raise "Checksum mismatch for downloaded blob" if file_checksum(destination_file) != sha
      end

    end
  end

  private
  def file_checksum(path)
    Digest::SHA1.file(path).hexdigest
  end
end