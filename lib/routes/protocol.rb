# Additive mirrors of the bare route surface, one set per protocol,
# sharing their route bodies with lib/routes/legacy.rb via
# define_protocol_routes (lib/app.rb). Registered explicitly per protocol
# rather than via a wildcard so an unknown protocol 404s straight from
# Sinatra instead of reaching the resolver.
#
# URL segments use hyphens (/web-mqtt, /management-tls) even though the
# protocol keys themselves stay underscored, since the keys mirror
# credentials.protocols verbatim. Only the hyphenated form is registered -
# no underscore alias.
RabbitMQ::Resolver::PROTOCOLS.each do |protocol|
  segment = protocol.tr('_', '-')
  define_protocol_routes("/#{segment}") { protocol }
end
