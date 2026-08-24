# The pre-consolidation route surface. Contract-frozen: method, path,
# request format, response format and status codes must not change.
#
# ping/queues/queue share their body with the protocol-prefixed routes in
# lib/routes/protocol.rb via define_protocol_routes (lib/app.rb); the only
# difference is that the bare routes resolve their protocol per request
# from selected_protocol rather than a fixed name.
define_protocol_routes('') { selected_protocol }

get '/env' do
  endpoint = endpoint_for(selected_protocol)
  scheme = endpoint.tls ? 'amqps' : 'amqp'
  status 200
  # Deliberately omits credentials, unlike the raw uris this replaces.
  body "rabbitmq_url: #{scheme}://#{endpoint.host}:#{endpoint.port}\n"
end
