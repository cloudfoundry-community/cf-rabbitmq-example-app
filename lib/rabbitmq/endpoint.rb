module RabbitMQ
  Endpoint = Struct.new(
    :protocol, :host, :port, :tls, :username, :password, :vhost, :source, :verify_peer,
    keyword_init: true
  ) do
    def advertised?
      source == :advertised
    end

    def derived?
      source == :derived
    end

    def verify_peer?
      tls && verify_peer
    end

    # Never includes the password - this is rendered by /protocols.
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
  end
end
