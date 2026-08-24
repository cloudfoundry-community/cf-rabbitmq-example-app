# Browser demo pages for the two WebSocket-only listeners. No Ruby client
# speaks MQTT or STOMP over WebSocket (see
# lib/rabbitmq/adapters/websocket.rb), so publish/consume for web_mqtt and
# web_stomp live here instead - in mqtt.js and stompjs, running in a
# browser, which is what these plugins exist for.
#
# These pages are served from repo-root public/, not settings.public_folder.
# Sinatra derives that default from `root`, which for this app resolves to
# lib/ (the directory of the first file to `require 'sinatra'`), so the
# default public_folder is lib/public - a directory that does not exist,
# which also leaves Sinatra's automatic static-file serving switched off.
# PUBLIC_DIR is computed independently of that setting so these routes
# work regardless of it.
helpers do
  def public_dir
    File.expand_path('../../public', __dir__)
  end
end

get '/web-mqtt/demo' do
  send_file File.join(public_dir, 'web-mqtt.html')
end

get '/web-stomp/demo' do
  send_file File.join(public_dir, 'web-stomp.html')
end

get '/js/mqtt.min.js' do
  send_file File.join(public_dir, 'js', 'mqtt.min.js')
end

get '/js/stomp.umd.min.js' do
  send_file File.join(public_dir, 'js', 'stomp.umd.min.js')
end

# The browser needs the endpoint, but never the password - the page
# prompts the viewer for credentials rather than receiving them from the
# server. Built field by field rather than serialising an Endpoint:
# relying on Endpoint#to_json's redaction here would be fragile against a
# future field added there. Any of the four keys can be legitimately
# absent (unadvertised and underivable), including all four at once -
# the report is then just {}, not an error.
get '/demo/config.json' do
  report = %w[web_mqtt web_mqtt_tls web_stomp web_stomp_tls].each_with_object({}) do |name, acc|
    endpoint = resolver.resolve(name)
    next unless endpoint

    acc[name] = {
      'url' => RabbitMQ::Registry.adapter_for(name).new(endpoint).url,
      'port' => endpoint.port,
      'vhost' => endpoint.vhost,
      'username' => endpoint.username
    }
  end

  content_type :json
  status 200
  body JSON.pretty_generate(report)
end

require 'rabbitmq/consistent_hash'

# x-consistent-hash is an AMQP concept, so this demo deliberately calls
# fallback_protocol rather than selected_protocol - the one place in the
# app where a viewer's protocol selection (query param or cookie) is
# intentionally ignored rather than honoured. Selecting stomp on the
# index page, for instance, must not steer this route onto anything
# other than AMQP.
post '/demo/consistent-hash' do
  queues = (params[:queues] || 3).to_i
  messages = (params[:messages] || 100).to_i
  halt 400, 'BAD-QUEUES' unless queues.between?(2, 20)
  halt 400, 'BAD-MESSAGES' unless messages.between?(1, 10_000)

  demo = RabbitMQ::ConsistentHash.new(endpoint_for(fallback_protocol), management)
  result = demo.run(queues: queues, messages: messages)
  content_type :json
  status 201
  body JSON.pretty_generate(result)
rescue RabbitMQ::ConsistentHash::PluginMissing => e
  halt 501, "NOT-SUPPORTED: #{e.message}"
end

# No dependency on a prior POST: #distribution/#total read whatever the
# management API currently reports, which is an empty hash when the demo
# queues do not exist yet - not a 404 or a raise.
get '/demo/consistent-hash' do
  demo = RabbitMQ::ConsistentHash.new(endpoint_for(fallback_protocol), management)
  content_type :json
  status 200
  body JSON.pretty_generate('distribution' => demo.distribution, 'total' => demo.total)
end
