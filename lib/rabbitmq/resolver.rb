require 'uri'
require_relative 'endpoint'

module RabbitMQ
  # Turns a protocol name into a concrete Endpoint.
  #
  # Preference order:
  #   1. credentials.protocols.<name>, used verbatim
  #   2. derived from the top-level host plus the protocol's standard port
  #
  # TLS is never decided by an environment variable - it follows the
  # resolved endpoint. See the design doc, "Absorbed requirements".
  class Resolver
    DEFAULT_PORTS = {
      'amqp' => 5672,
      'amqps' => 5671,
      'management' => 15672,
      'management_tls' => 15671,
      'mqtt' => 1883,
      'mqtts' => 8883,
      'stomp' => 61613,
      'stomps' => 61614,
      'web_mqtt' => 15675,
      'web_mqtt_tls' => 15676,
      'web_stomp' => 15674
      # web_stomp_tls is deliberately absent: RabbitMQ documents no default
      # TLS port for web-stomp, so it can only be used when advertised.
    }.freeze

    TLS_PROTOCOLS = %w[amqps management_tls mqtts stomps web_mqtt_tls web_stomp_tls].freeze

    PROTOCOLS = (DEFAULT_PORTS.keys + ['web_stomp_tls']).freeze

    # MQTT takes no vhost from the connection; it uses the vhost:username
    # form. Blacksmith gives every instance its own vhost, so without this
    # an MQTT client silently lands on "/".
    VHOST_PREFIXED = %w[mqtt mqtts web_mqtt web_mqtt_tls].freeze

    def initialize(binding, env = ENV)
      @binding = binding
      @env = env
    end

    def resolve(name)
      name = name.to_s
      return nil unless @binding.bound?
      return nil unless PROTOCOLS.include?(name)

      advertised(name) || derived(name)
    end

    def unavailable_reason(name)
      name = name.to_s
      return 'no RabbitMQ service bound to this application' unless @binding.bound?
      return "unknown protocol: #{name}" unless PROTOCOLS.include?(name)
      return nil if resolve(name)

      if name == 'web_stomp_tls'
        'web-stomp over TLS has no documented default port; it must be ' \
          'advertised in the binding or configured explicitly'
      else
        "#{name} is not advertised in the binding and could not be derived"
      end
    end

    private

    def advertised(name)
      block = @binding.protocol(name)
      return nil unless block

      host = block['host'] || default_host
      port = block['port'] || DEFAULT_PORTS[name]
      return nil unless host && port

      build(
        name,
        host: host,
        port: port,
        tls: advertised_tls?(name, block),
        source: :advertised
      )
    end

    # An explicit "ssl" flag is coerced through the same strict boolean
    # parsing as RABBITMQ_VERIFY_PEER, never trusted verbatim - a broker
    # that hands back the JSON string "false" must not be treated as
    # truthy. A missing (or explicitly null) flag falls back to what the
    # protocol name implies.
    def advertised_tls?(name, block)
      raw = block['ssl']
      return TLS_PROTOCOLS.include?(name) if raw.nil?

      strict_bool!(raw, 'ssl')
    end

    def derived(name)
      port = DEFAULT_PORTS[name]
      return nil unless port
      return nil unless default_host

      tls = derived_tls?(name)
      return nil if tls.nil?

      build(name, host: default_host, port: port, tls: tls, source: :derived)
    end

    # For the AMQP pair the top-level uri scheme is authoritative when
    # protocols is absent. The pair's default port is fixed to the
    # requested protocol name, so a uri whose scheme disagrees with the
    # requested name (an "amqp" request against an amqps:// uri, or vice
    # versa) cannot be derived without pairing the wrong TLS-ness with the
    # wrong port - nil says "not derivable" rather than emitting a
    # mismatched endpoint. For everything else the protocol name decides.
    def derived_tls?(name)
      return TLS_PROTOCOLS.include?(name) unless %w[amqp amqps].include?(name)

      uri = credentials['uri'] || Array(credentials['uris']).first
      return TLS_PROTOCOLS.include?(name) unless uri

      uri_tls = uri.start_with?('amqps://')
      return nil unless uri_tls == (name == 'amqps')

      uri_tls
    end

    def build(name, host:, port:, tls:, source:)
      Endpoint.new(
        protocol: name,
        host: host,
        port: port,
        tls: tls,
        username: username_for(name),
        password: credentials['password'],
        vhost: vhost,
        source: source,
        verify_peer: verify_peer_setting
      )
    end

    def username_for(name)
      user = credentials['username']
      VHOST_PREFIXED.include?(name) ? "#{vhost}:#{user}" : user
    end

    def vhost
      credentials['vhost'] || '/'
    end

    def default_host
      credentials['host'] || credentials['hostname'] ||
        Array(credentials['hostnames']).first || credentials['dnsname']
    end

    def credentials
      @binding.credentials || {}
    end

    # Strict parsing: never treat an arbitrary string as truthy.
    def verify_peer_setting
      raw = @env['RABBITMQ_VERIFY_PEER']
      return true if raw.nil? || raw.empty?

      strict_bool!(raw, 'RABBITMQ_VERIFY_PEER')
    end

    # Shared strict boolean coercion for RABBITMQ_VERIFY_PEER and the
    # advertised "ssl" flag: only true/false/1/0 (or those strings,
    # case-insensitively) are accepted. Never guesses at an arbitrary
    # string's truthiness.
    def strict_bool!(raw, label)
      return raw if raw == true || raw == false

      case raw.to_s.downcase
      when 'true', '1' then true
      when 'false', '0' then false
      else
        raise ArgumentError,
              "#{label} must be one of true, false, 1, 0 - got #{raw.inspect}"
      end
    end
  end
end
