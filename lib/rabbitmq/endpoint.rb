require 'json'

module RabbitMQ
  Endpoint = Struct.new(
    :protocol, :host, :port, :tls, :username, :password, :vhost, :source, :verify_peer,
    keyword_init: true
  ) do
    REDACTED_FIELD = :password
    REDACTED_LABEL = 'FILTERED'.freeze

    def advertised?
      source == :advertised
    end

    def derived?
      source == :derived
    end

    def verify_peer?
      tls && verify_peer
    end

    # Never includes the credential field - this is rendered by /protocols.
    def to_h
      {
        'protocol' => protocol,
        'host' => host,
        'port' => port,
        'tls' => tls,
        'vhost' => vhost,
        'username' => username,
        'source' => source.to_s
      }
    end

    # Struct's default #inspect (and the #to_s aliased to it) prints every
    # member, credential field included. Override both so no accidental
    # log line, 500 page, or `json endpoint` call can leak it - the safe
    # #to_h path must not be the only safe path.
    def inspect
      fields = to_h.map { |k, v| "#{k}=#{v.inspect}" }.join(' ')
      "#<RabbitMQ::Endpoint #{fields} #{REDACTED_FIELD}=[#{REDACTED_LABEL}]>"
    end
    alias to_s inspect

    def to_json(*args)
      to_h.to_json(*args)
    end
  end
end
