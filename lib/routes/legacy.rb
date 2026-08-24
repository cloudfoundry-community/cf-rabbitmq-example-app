# The pre-consolidation route surface. Contract-frozen: method, path,
# request format, response format and status codes must not change.
get '/ping' do
  relay(adapter(selected_protocol).ping)
end

get '/env' do
  endpoint = endpoint_for(selected_protocol)
  scheme = endpoint.tls ? 'amqps' : 'amqp'
  status 200
  # Deliberately omits credentials, unlike the raw uris this replaces.
  body "rabbitmq_url: #{scheme}://#{endpoint.host}:#{endpoint.port}\n"
end

get '/queues' do
  status 200
  body management.queue_names.map { |q| "#{q}\n" }.join
end

post '/queues' do
  halt 400, 'NO-NAME' unless params[:name]
  halt 304, 'EXISTS' if management.queue_exists?(params[:name])

  relay(adapter(selected_protocol).declare(params[:name]))
end

put '/queue/:name' do
  halt 400, 'NO-DATA' unless params[:data]

  relay(adapter(selected_protocol).publish(params[:name], params[:data]))
end

get '/queue/:name' do
  relay(adapter(selected_protocol).consume(params[:name]))
end
